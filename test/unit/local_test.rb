# frozen_string_literal: true

require_relative "../test_helper"

class LocalTest < Minitest::Test
  def setup
    @project = File.join(tmpdir, "project")
    FileUtils.mkdir_p(File.join(@project, "etc/kamal"))
    File.write(File.join(@project, "etc/kamal/deploy.yml"), "service: example\n")
  end

  def local(*argv, env: {})
    @execs = []
    out = StringIO.new
    result = Dir.chdir(@project) do
      CiDeploy::Local.new(argv, env: env, out: out, exec: ->(exec_env, exec_argv) { @execs << [exec_env, exec_argv] }).call
    end
    [result, out.string]
  end

  def test_parse_env_file_handles_export_quotes_comments_and_multiline_values
    values = CiDeploy::Local.parse_env_file(<<~'ENV')
      # local credentials
      export SSH_USER=deploy
      REGISTRY_PASSWORD='single $quoted'
      SSH_KEY="line one\nline two"
      PLAIN=value # trailing comment
      EMPTY=
    ENV
    assert_equal({ "SSH_USER" => "deploy", "REGISTRY_PASSWORD" => "single $quoted", "SSH_KEY" => "line one\nline two",
                   "PLAIN" => "value", "EMPTY" => "" }, values)
  end

  def test_parse_env_file_rejects_lines_that_are_not_assignments
    assert_raises(CiDeploy::Local::Usage) { CiDeploy::Local.parse_env_file("rm -rf /\n") }
  end

  def test_other_commands_pass_through_with_the_configuration_added
    local("--config", "etc/kamal/deploy.yml", "app", "logs", "-d", "staging")
    assert_equal [%w[kamal app logs -d staging -c etc/kamal/deploy.yml]], @execs.map(&:last)
  end

  def test_an_explicit_config_in_the_kamal_arguments_is_kept
    local("app", "details", "-c", "etc/kamal/other.yml")
    assert_equal [%w[kamal app details -c etc/kamal/other.yml]], @execs.map(&:last)
  end

  def test_env_files_are_loaded_in_order_and_the_config_is_exported
    File.write(File.join(@project, "a.env"), "SSH_USER=first\nSSH_PORT=2222\n")
    File.write(File.join(@project, "b.env"), "SSH_USER=second\n")
    env = {}
    local("--env-file", "a.env", "--env-file", "b.env", "app", "details", env: env)
    assert_equal "second", env["SSH_USER"]
    assert_equal "2222", env["SSH_PORT"]
    assert_equal "etc/kamal/deploy.yml", env["CI_DEPLOY_CONFIG"]
  end

  def test_missing_env_file_is_an_error
    assert_raises(CiDeploy::Local::Usage) { local("--env-file", "missing.env", "app", "details") }
  end

  def test_the_default_secrets_file_is_copied_like_ci_does
    File.write(File.join(@project, "etc/kamal/secrets-common"), "KAMAL_REGISTRY_PASSWORD=$REGISTRY_PASSWORD\n")
    local("app", "details")
    assert_equal "KAMAL_REGISTRY_PASSWORD=$REGISTRY_PASSWORD\n", File.read(File.join(@project, ".kamal/secrets-common"))
  end

  def test_outputs_map_needs_a_workspace_and_a_token
    File.write(File.join(@project, "outputs.map"), "WEB_SERVER_IPS=web_server_ips\n")
    assert_raises(CiDeploy::Local::Usage) { local("--outputs-map", "outputs.map", "app", "details") }
    assert_raises(CiDeploy::TerraformOutputs::Error) do
      local("--outputs-map", "outputs.map", "--terraform-workspace", "ws-abc", "app", "details", env: {})
    end
  end

  def test_no_kamal_command_is_an_error
    assert_raises(CiDeploy::Local::Usage) { local("--config", "etc/kamal/deploy.yml") }
  end

  def test_prebuilt_deploy_needs_a_version
    assert_raises(CiDeploy::Local::Usage) { local("deploy", "--skip-push") }
  end

  def test_deploy_rejects_unsupported_flags
    assert_raises(CiDeploy::Local::Usage) { local("deploy", "--roles", "web") }
  end
end

# `deploy` through the launcher, end to end with recording kamal, docker and git.
class LocalDeployTest < Minitest::Test
  SHA = "0123456789abcdef0123456789abcdef01234567"

  def setup
    @project = File.join(tmpdir, "project")
    FileUtils.mkdir_p(File.join(@project, "etc/kamal"))
    File.write(File.join(@project, "etc/kamal/deploy.yml"), "service: example\n")
    @stubs = TestSupport::Stubs.new(tmpdir)
    @stubs.add("git", <<~SH)
      case "$*" in
        "rev-parse HEAD") echo #{SHA} ;;
        "rev-parse --abbrev-ref HEAD") echo main ;;
        "status --porcelain") ;;
      esac
    SH
    @stubs.add("kamal", <<~SH)
      case "$1 $2" in
        "app version") printf 'App Host: 192.0.2.10\\nprevious-version\\n\\n' ;;
        "config --version") printf -- '---\\n:absolute_image: registry.example.com/example/app:%s\\n' "$3" ;;
        "deploy --skip-push") echo "REGISTRY_PASSWORD=$REGISTRY_PASSWORD" ;;
      esac
    SH
  end

  def launch(*args, published: true)
    @stubs.add("docker", published ? "exit 0" : "echo 'manifest unknown'; exit 1")
    env = { "PATH" => @stubs.path, "CI_DEPLOY_HOME" => ROOT }
    Open3.capture2e(clean_env(env), RbConfig.ruby, File.join(ROOT, "bin/ci-deploy"), "local", *args, chdir: @project, **spawn_options)
  end

  def test_prebuilt_deploy_refuses_an_unpublished_image_and_touches_no_host
    output, status = launch("deploy", "--skip-push", "--version", "release-7", published: false)

    refute status.success?
    assert_includes output, "is not published in the registry"
    refute(@stubs.calls_to("kamal").any? { |args| args.first == "deploy" })
    assert_includes @stubs.calls_to("docker"), ["manifest", "inspect", "registry.example.com/example/app:release-7"]
  end

  def test_prebuilt_deploy_of_a_published_image_deploys_that_version
    File.write(File.join(@project, "local.env"), "REGISTRY_PASSWORD=\"multi\\nline\"\n")
    output, status = launch("--env-file", "local.env", "deploy", "--skip-push", "--version", "release-7", "-d", "production")

    assert status.success?, output
    assert_includes @stubs.calls_to("kamal"), ["deploy", "--skip-push", "--version=release-7", "-c", "etc/kamal/deploy.yml", "-d", "production"]
    refute(@stubs.calls_to("kamal").any? { |args| args.first == "build" })
    assert_includes output, "REGISTRY_PASSWORD=multi\nline"
  end

  def test_built_deploy_uses_one_version_from_git
    output, status = launch("deploy")

    assert status.success?, output
    assert_includes @stubs.calls_to("kamal"), ["build", "push", "--version=#{SHA}", "-c", "etc/kamal/deploy.yml"]
    assert_includes @stubs.calls_to("kamal"), ["deploy", "--skip-push", "--version=#{SHA}", "-c", "etc/kamal/deploy.yml"]
  end

  def test_branch_policy_applies_locally
    output, status = launch("deploy", "-d", "staging")
    refute status.success?
    assert_includes output, "reserved for production"
    assert_empty @stubs.calls_to("kamal")
  end
end
