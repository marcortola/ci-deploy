# frozen_string_literal: true

require_relative "../test_helper"

# The steps of the deploy action, run as the action runs them: separate processes sharing only
# the GitHub files and the environment.
class CliTest < Minitest::Test
  SHA = "0123456789abcdef0123456789abcdef01234567"

  def setup
    @gh = TestSupport::GithubFiles.new
    @project = File.join(tmpdir, "project")
    FileUtils.mkdir_p(File.join(@project, "etc/kamal"))
    File.write(File.join(@project, "etc/kamal/deploy.yml"), "service: example\n")
    @stubs = TestSupport::Stubs.new(tmpdir)
    @stubs.add("git", "case \"$*\" in \"rev-parse HEAD\") echo #{SHA} ;; esac")
    kamal(build: 0, deploy: 0)
  end

  def teardown = @gh.cleanup

  def kamal(build:, deploy:)
    @stubs.add("kamal", <<~SH)
      case "$1" in
        app) printf 'App Host: 192.0.2.10\\nprevious\\n\\n' ;;
        build) exit #{build} ;;
        deploy) exit #{deploy} ;;
      esac
    SH
  end

  def step(command, inputs = {}, env = {})
    base = @gh.env.merge("PATH" => @stubs.path, "CI_DEPLOY_HOME" => ROOT, "CI_DEPLOY_ACTION_HOME" => ROOT,
                         "CI_DEPLOY_PROJECT_DIR" => @project, "CI_DEPLOY_CONFIG" => "etc/kamal/deploy.yml",
                         "GITHUB_REF_NAME" => "main", "GITHUB_SHA" => SHA, "GITHUB_REPOSITORY" => "example/app")
    inputs.each { |name, value| base["CI_DEPLOY_IN_#{name.to_s.upcase}"] = value }
    Open3.capture2e(clean_env(base.merge(env)), RbConfig.ruby, File.join(ROOT, "bin/ci-deploy"), command, **spawn_options)
  end

  def test_unknown_command_prints_usage
    output, status = step("nope")
    assert_equal 2, status.exitstatus
    assert_includes output, "usage: ci-deploy"
  end

  def test_successful_deploy_and_finish
    _output, status = step("deploy")
    assert status.success?
    assert_equal "success", @gh.outputs["deploy-result"]
    _output, status = step("finish", result: "success", rollback_result: "not-needed")
    assert status.success?
  end

  def test_failed_build_only_reads_from_hosts_and_finish_keeps_the_failure
    kamal(build: 1, deploy: 0)
    _output, status = step("deploy", rollback: "auto")
    refute status.success?
    assert_equal [%w[app version], %w[build push]], @stubs.calls_to("kamal").map { |args| args.first(2) }
    assert_equal "build-failed", @gh.outputs["deploy-result"]

    output, status = step("finish", result: "build-failed", rollback_result: "not-attempted")
    refute status.success?
    assert_includes output, "Deploy finished with result 'build-failed'"
  end

  def test_branch_policy_violation_reports_refused_and_runs_nothing
    output, status = step("deploy", { destination: "staging" })
    refute status.success?
    assert_includes output, "reserved for production"
    assert_equal({ "deploy-result" => "refused", "rollback-result" => "not-attempted" }, @gh.outputs)
    assert_empty @stubs.calls_to("kamal")
  end

  def test_branch_policy_off_and_custom_production_names
    _output, status = step("deploy", { destination: "staging", branch_policy: "off" })
    assert status.success?
    _output, status = step("deploy", { destination: "live", production_branch: "release", production_destination: "live" },
                           "GITHUB_REF_NAME" => "release")
    assert status.success?
  end

  def test_cleanup_failure_after_a_failed_deploy_keeps_the_original_result
    kamal(build: 0, deploy: 1)
    _output, status = step("deploy")
    refute status.success?
    assert_equal "deploy-failed", @gh.outputs["deploy-result"]

    @stubs.add("cleanup-tool", "exit 9")
    output, status = step("cleanup", cleanup_command: "cleanup-tool --resume 'telemetry stack'")
    assert status.success?, "a failing cleanup must not change the step result"
    assert_includes output, "exited with status 9; the deploy result is unchanged"
    assert_equal [["--resume", "telemetry stack"]], @stubs.calls_to("cleanup-tool")

    _output, status = step("notify", result: "deploy-failed", rollback_result: "disabled")
    assert status.success?
    output, status = step("finish", result: "deploy-failed", rollback_result: "disabled")
    refute status.success?
    assert_includes output, "'deploy-failed'"
  end

  def test_cleanup_command_is_not_run_through_a_shell
    marker = File.join(tmpdir, "pwned")
    @stubs.add("cleanup-tool")
    _output, status = step("cleanup", cleanup_command: "cleanup-tool resume; touch #{marker}")
    assert status.success?
    refute File.exist?(marker)
    assert_equal [["resume;", "touch", marker]], @stubs.calls_to("cleanup-tool")
  end

  def test_unparseable_cleanup_command_only_warns
    output, status = step("cleanup", cleanup_command: "tool 'unterminated")
    assert status.success?
    assert_includes output, "::warning::The cleanup command could not be parsed"
  end

  def test_notify_failure_never_fails_the_step
    output, status = step("notify", { rollbar_token: "token", result: "deploy-failed" },
                          "CI_DEPLOY_ROLLBAR_ENDPOINT" => "http://127.0.0.1:9")
    assert status.success?, output
    assert_includes output, "::warning::Could not report the deploy to Rollbar"
  end

  def test_finish_without_a_result_reports_an_interrupted_deploy
    output, status = step("finish")
    refute status.success?
    assert_includes output, "unknown (the deploy step did not complete)"
  end

  def test_finish_flags_a_failed_rollback_even_when_reporting_the_deploy_result
    output, status = step("finish", result: "deploy-failed", rollback_result: "failed")
    refute status.success?
    assert_includes output, "The rollback did not complete"
  end

  def test_deploy_needs_the_setup_action
    output, status = step("deploy", {}, "CI_DEPLOY_HOME" => nil)
    refute status.success?
    assert_includes output, "run the setup action first"

    output, status = step("deploy", {}, "CI_DEPLOY_PROJECT_DIR" => nil)
    refute status.success?
    assert_includes output, "CI_DEPLOY_PROJECT_DIR is not set"
  end

  def test_deploy_from_another_revision_is_refused
    other = File.join(tmpdir, "other")
    FileUtils.mkdir_p(other)
    output, status = step("deploy", {}, "CI_DEPLOY_ACTION_HOME" => other)
    refute status.success?
    assert_includes output, "pin every marcortola/ci-deploy action to the same SHA"
    assert_empty @stubs.calls_to("kamal")
  end

  def test_export_env_and_kamal_env
    _output, status = step("export-env", vars: '{"APP_HOST":"app.example.com"}', secrets: %({"SSH_KEY":"a\\nb"}))
    assert status.success?
    _output, status = step("kamal-env", registry: "registry.example.com", registry_password: "pw", ssh_user: "deploy")
    assert status.success?
    assert_equal({ "APP_HOST" => "app.example.com", "SSH_KEY" => "a\nb", "REGISTRY" => "registry.example.com",
                   "REGISTRY_PASSWORD" => "pw", "SSH_USER" => "deploy" }, @gh.exported)
  end

  def test_terraform_outputs_failure_fails_the_step_without_exporting
    output, status = step("terraform-outputs", { outputs_map: "WEB_SERVER_IPS=web_server_ips", terraform_token: "t",
                                                terraform_workspace: "ws-abc", terraform_address: "http://127.0.0.1:9" })
    refute status.success?
    assert_includes output, "could not be reached"
    assert_empty @gh.exported
  end

  def test_prepare_secrets_copies_the_file_and_refuses_a_missing_one
    File.write(File.join(@project, "etc/kamal/secrets-common"), "A=$A\n")
    _output, status = step("prepare-secrets", secrets_file: "etc/kamal/secrets-common")
    assert status.success?
    assert File.file?(File.join(@project, ".kamal/secrets-common"))

    output, status = step("prepare-secrets", secrets_file: "etc/kamal/missing")
    refute status.success?
    assert_includes output, "secrets file etc/kamal/missing not found"
  end
end
