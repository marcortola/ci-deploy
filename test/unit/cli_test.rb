# frozen_string_literal: true

require_relative "../test_helper"
require "socket"

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

  # The deploy step needs an explicit rollback policy; tests that are not about it use off.
  def step(command, inputs = {}, env = {})
    inputs = { rollback: "off" }.merge(inputs) if command == "deploy"
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

  def test_the_rollback_policy_is_required
    output, status = step("deploy", rollback: "")
    refute status.success?
    assert_includes output, "the rollback input is required: auto or off"
    assert_equal({ "deploy-result" => "error", "rollback-result" => "not-attempted" }, @gh.outputs)
    assert_empty @stubs.calls_to("kamal")
  end

  def test_an_invalid_version_reports_error_not_cancelled
    output, status = step("deploy", version: "not a tag")
    refute status.success?
    assert_includes output, "is not a valid image tag"
    assert_equal "error", @gh.outputs["deploy-result"]
    assert_equal "not-attempted", @gh.outputs["rollback-result"]
    assert_empty @stubs.calls_to("kamal")
  end

  def test_a_project_that_is_not_a_git_checkout_reports_error
    @stubs.add("git", "exit 128")
    output, status = step("deploy", branch_policy: "off")
    refute status.success?
    assert_includes output, "is not a git checkout"
    assert_equal "error", @gh.outputs["deploy-result"]
  end

  def test_a_failing_kamal_config_in_prebuilt_mode_reports_error
    @stubs.add("kamal", <<~SH)
      case "$1" in
        app) printf 'App Host: 192.0.2.10\nprevious\n\n' ;;
        config) echo "ERROR (KeyError): missing secret" >&2; exit 1 ;;
      esac
    SH
    output, status = step("deploy", build_mode: "prebuilt", version: "v2")
    refute status.success?
    assert_includes output, "kamal config failed"
    assert_equal "error", @gh.outputs["deploy-result"]
    assert_equal "not-attempted", @gh.outputs["rollback-result"]
    refute(@stubs.calls_to("kamal").any? { |args| args.first == "deploy" })
  end

  def test_an_error_result_is_reported_as_failed_and_re_raised
    output, status = step("finish", result: "error", rollback_result: "not-attempted")
    refute status.success?
    assert_includes output, "Deploy finished with result 'error'"
  end

  def test_enforce_refuses_a_checkout_that_is_not_the_workflow_commit
    @stubs.add("git", "case \"$*\" in \"rev-parse HEAD\") echo #{"f" * 40} ;; esac")
    output, status = step("deploy")
    refute status.success?
    assert_includes output, "not the workflow's commit #{SHA}"
    assert_equal({ "deploy-result" => "refused", "rollback-result" => "not-attempted" }, @gh.outputs)
    assert_empty @stubs.calls_to("kamal")

    _output, status = step("deploy", branch_policy: "off")
    assert status.success?, "branch-policy off deploys the checkout as it is"
  end

  def test_enforce_refuses_when_the_checkout_commit_cannot_be_read
    @stubs.add("git", "echo 'fatal: not a git repository' >&2; exit 128")
    output, status = step("deploy")
    refute status.success?
    assert_includes output, "::error::Could not read the checkout's commit (git rev-parse HEAD exited with status 128)"
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

  # The setup action puts this repository's bin/ on PATH (after the stubs here, so kamal and ssh record).
  def host_control_env
    @stubs.add("ssh")
    { "PATH" => "#{@stubs.path}:#{File.join(ROOT, 'bin')}", "SSH_USER" => "deploy", "SERVER_IPS" => "192.0.2.10",
      "KAMAL_DESTINATION" => "production" }
  end

  def test_host_control_skips_a_staging_deploy_through_the_before_deploy_and_cleanup_commands
    command = "ci-deploy-host-control --command /usr/local/sbin/example-control"
    env = host_control_env
    output, status = step("deploy", { destination: "staging", branch_policy: "off", before_deploy_command: "#{command} pause" }, env)
    assert status.success?, output
    _output, status = step("cleanup", { destination: "staging", cleanup_command: "#{command} resume" }, env)
    assert status.success?
    assert_empty @stubs.calls_to("ssh"), "a job-level KAMAL_DESTINATION must not leak into a staging deploy"
  end

  def test_host_control_runs_for_production_through_the_before_deploy_and_cleanup_commands
    command = "ci-deploy-host-control --command /usr/local/sbin/example-control"
    env = host_control_env
    output, status = step("deploy", { destination: "production", before_deploy_command: "#{command} pause" }, env)
    assert status.success?, output
    _output, status = step("cleanup", { destination: "production", cleanup_command: "#{command} resume" }, env)
    assert status.success?
    assert_equal ["sudo -n /usr/local/sbin/example-control pause", "sudo -n /usr/local/sbin/example-control resume"],
                 @stubs.calls_to("ssh").map(&:last)
  end

  def test_without_a_destination_the_commands_see_no_kamal_destination
    @stubs.add("show-destination", %(echo "destination=${KAMAL_DESTINATION-unset}" >> "#{tmpdir}/destination.log"))
    _output, status = step("deploy", { before_deploy_command: "show-destination" }, "KAMAL_DESTINATION" => "staging")
    assert status.success?
    _output, status = step("cleanup", { cleanup_command: "show-destination" }, "KAMAL_DESTINATION" => "staging")
    assert status.success?
    assert_equal "destination=unset\ndestination=unset\n", File.read(File.join(tmpdir, "destination.log"))
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

  # An error outside the expected classes (here Errno::ENOENT from a missing action path) still
  # sets the error result, fails the step with an annotation and runs nothing.
  def test_an_unexpected_error_in_the_deploy_step_reports_error
    output, status = step("deploy", {}, "CI_DEPLOY_ACTION_HOME" => File.join(tmpdir, "missing"))
    assert_equal 1, status.exitstatus
    assert_includes output, "::error::Unexpected Errno::ENOENT"
    assert_equal({ "deploy-result" => "error", "rollback-result" => "not-attempted" }, @gh.outputs)
    assert_empty @stubs.calls_to("kamal")
  end

  # Once kamal deploy has run, an unexpected error cannot say whether a host changed or the
  # rollback completed: the rollback result is unknown, never not-attempted.
  def test_an_unexpected_error_after_kamal_deploy_ran_reports_an_unknown_rollback
    kamal(build: 0, deploy: 1)
    fault = File.join(tmpdir, "fault.rb")
    File.write(fault, <<~RUBY)
      $LOAD_PATH.unshift #{File.join(ROOT, 'lib').inspect}
      require "ci_deploy/cli"
      CiDeploy::Rollback.prepend(Module.new { def call(*) = raise(IOError, "connection lost during the rollback") })
    RUBY
    output, status = step("deploy", { rollback: "auto" }, "RUBYOPT" => "-r#{fault}")
    assert_equal 1, status.exitstatus
    assert_includes output, "::error::Unexpected IOError: connection lost during the rollback"
    assert(@stubs.calls_to("kamal").any? { |args| args.first == "deploy" })
    assert_equal "error", @gh.outputs["deploy-result"]
    assert_equal "unknown", @gh.outputs["rollback-result"]

    output, status = step("finish", result: "error", rollback_result: "unknown")
    refute status.success?
    assert_includes output, "intervene manually"
    assert_includes output, "Deploy finished with result 'error'"
  end

  def test_an_unexpected_error_in_another_step_fails_it_with_an_annotation
    File.write(File.join(@project, "etc/kamal/secrets-common"), "A=$A\n")
    File.write(File.join(@project, ".kamal"), "a file where the directory belongs\n")
    output, status = step("prepare-secrets", secrets_file: "etc/kamal/secrets-common")
    assert_equal 1, status.exitstatus
    assert_includes output, "::error::Unexpected Errno::EEXIST"

    output, status = step("operation", { operation: "proxy-details" }, "CI_DEPLOY_ACTION_HOME" => File.join(tmpdir, "missing"))
    assert_equal 1, status.exitstatus
    assert_includes output, "::error::Unexpected Errno::ENOENT"
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

# The setup action's failure report, run as the action runs it against a local stand-in for
# Rollbar that records each request.
class SetupFailureReportTest < Minitest::Test
  class FakeRollbar
    attr_reader :requests

    def initialize(status: 200)
      @status = status
      @requests = []
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new do
        loop { serve(@server.accept) }
      rescue IOError
        nil
      end
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    def stop
      @server.close
      @thread.join
    end

    private

    def serve(client)
      path = client.gets.to_s.split[1]
      headers = {}
      while (line = client.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      body = client.read(headers["content-length"].to_i)
      @requests << { path: path, token: headers["x-rollbar-access-token"], body: JSON.parse(body) }
      client.write("HTTP/1.1 #{@status} Status\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
    ensure
      client.close
    end
  end

  TOKEN = "rollbar-token-from-secrets"

  def setup
    @gh = TestSupport::GithubFiles.new
    @rollbar = FakeRollbar.new
  end

  def teardown
    @rollbar.stop
    @gh.cleanup
  end

  # No CI_DEPLOY_HOME or project directory: the failure may come before setup records them.
  def report(inputs, env = {})
    base = @gh.env.merge("CI_DEPLOY_ROLLBAR_ENDPOINT" => @rollbar.url, "GITHUB_REPOSITORY" => "example/app",
                         "GITHUB_SHA" => "abc123", "GITHUB_RUN_ID" => "7")
    inputs.each { |name, value| base["CI_DEPLOY_IN_#{name.to_s.upcase}"] = value }
    Open3.capture2e(clean_env(base.merge(env)), RbConfig.ruby, File.join(ROOT, "bin/ci-deploy"), "report-setup-failure", **spawn_options)
  end

  def test_reports_a_failed_deploy_and_a_critical_item_with_the_token_from_the_secrets_json
    output, status = report(report_destination: "staging", secrets: JSON.generate("ROLLBAR_SERVER_TOKEN" => TOKEN, "OTHER" => "x"))
    assert status.success?, output
    deploy, item = @rollbar.requests
    assert_equal ["/api/1/deploy", "/api/1/item/"], @rollbar.requests.map { |request| request[:path] }
    assert_equal TOKEN, deploy[:token]
    assert_equal({ "environment" => "staging", "revision" => "abc123", "status" => "failed" }, deploy[:body].slice("environment", "revision", "status"))
    assert_equal TOKEN, item[:body]["access_token"]
    assert_equal "critical", item[:body]["data"]["level"]
    assert_includes item[:body]["data"]["body"]["message"]["body"], "setup-failed"
    refute_includes output, TOKEN
  end

  def test_the_explicit_token_and_environment_name_win_and_an_environment_name_alone_reports
    _output, status = report(report_destination: "staging", report_environment_name: "stage-eu", rollbar_token: "explicit",
                             secrets: JSON.generate("ROLLBAR_TOKEN" => TOKEN))
    assert status.success?
    assert_equal "explicit", @rollbar.requests.first[:token]
    assert_equal "stage-eu", @rollbar.requests.first[:body]["environment"]

    _output, status = report(report_environment_name: "production", secrets: JSON.generate("ROLLBAR_TOKEN" => TOKEN))
    assert status.success?
    assert_equal "production", @rollbar.requests.last[:body]["data"]["environment"]
  end

  def test_silent_without_a_destination_or_environment_to_report
    output, status = report(secrets: JSON.generate("ROLLBAR_TOKEN" => TOKEN))
    assert status.success?, output
    assert_empty output
    assert_empty @rollbar.requests
  end

  def test_without_a_token_it_only_notes_that_it_skipped
    output, status = report({ report_destination: "staging", secrets: "not json" }, "ROLLBAR_TOKEN" => nil)
    assert status.success?, output
    assert_includes output, "::notice::No Rollbar token configured; the setup failure is not reported to Rollbar."
    assert_empty @rollbar.requests

    _output, status = report({ report_destination: "staging", secrets: "not json" }, "ROLLBAR_TOKEN" => "from-env")
    assert status.success?
    assert_equal "from-env", @rollbar.requests.first[:token]
  end

  def test_a_rollbar_error_or_an_unreachable_rollbar_is_swallowed
    @rollbar.stop
    @rollbar = FakeRollbar.new(status: 500)
    output, status = report(report_destination: "staging", secrets: JSON.generate("ROLLBAR_TOKEN" => TOKEN))
    assert status.success?, output
    assert_includes output, "::warning::Rollbar answered HTTP 500 to the deploy report"
    assert_includes output, "::warning::Rollbar answered HTTP 500 to the item report"

    output, status = report({ report_destination: "staging", secrets: JSON.generate("ROLLBAR_TOKEN" => TOKEN) },
                            "CI_DEPLOY_ROLLBAR_ENDPOINT" => "http://127.0.0.1:9")
    assert status.success?, output
    assert_includes output, "::warning::Could not report the deploy to Rollbar"
    refute_includes output, TOKEN
  end
end
