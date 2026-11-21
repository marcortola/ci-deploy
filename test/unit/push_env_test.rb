# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"
require "socket"

# bin/ci-deploy-push-env with the locked Kamal and no server: a failing pre-connect hook records
# what Kamal dispatched, and a closed SSH port stops a run with hooks skipped at its first
# connection. The upload itself runs against real hosts in the integration suite.
class PushEnvTest < Minitest::Test
  SCRIPT = File.join(ROOT, "bin/ci-deploy-push-env")
  SECRET = "push-env-secret-value"

  def setup
    @project = File.join(tmpdir, "project")
    FileUtils.mkdir_p(File.join(@project, "etc/kamal"))
    FileUtils.mkdir_p(File.join(@project, ".kamal/hooks"))
    File.write(File.join(@project, "etc/kamal/deploy.yml"), <<~YAML)
      service: push-env-example
      image: example/push-env
      servers:
        web:
          hosts: [127.0.0.1]
      registry:
        server: registry.example.com
        username: example-user
        password: [KAMAL_REGISTRY_PASSWORD]
      ssh:
        port: #{closed_port}
      builder:
        arch: amd64
      env:
        secret: [PUSH_ENV_SECRET]
    YAML
    File.write(File.join(@project, "etc/kamal/deploy.staging.yml"), "env:\n  clear:\n    STAGE: staging\n")
    File.write(File.join(@project, ".kamal/secrets"), "KAMAL_REGISTRY_PASSWORD=example-password\nPUSH_ENV_SECRET=#{SECRET}\n")
    @hook_env = File.join(tmpdir, "pre-connect.env")
    hook = File.join(@project, ".kamal/hooks/pre-connect")
    File.write(hook, "#!/bin/sh\nenv | grep '^KAMAL_' > '#{@hook_env}'\nexit 1\n")
    File.chmod(0o755, hook)
  end

  # A port nothing listens on, so an SSH connection is refused at once.
  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def push(*args, env: {})
    base = { "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "HOME" => tmpdir }
    Open3.capture3(clean_env(base.merge(env)), RbConfig.ruby, SCRIPT, *args, chdir: @project, **spawn_options)
  end

  def hook_env
    File.read(@hook_env).lines(chomp: true).to_h { |line| line.split("=", 2) }
  end

  def test_runs_the_hidden_kamal_app_boot_env_with_the_deploys_arguments
    stdout, stderr, status = push("-c", "etc/kamal/deploy.yml", "-d", "staging", "--version=release-1")

    assert_equal 1, status.exitstatus, stdout + stderr
    assert_includes stderr, "ERROR (Kamal::Cli::HookError): Hook `pre-connect` failed"
    assert_equal({ "KAMAL_COMMAND" => "app", "KAMAL_SUBCOMMAND" => "boot_env", "KAMAL_VERSION" => "release-1",
                   "KAMAL_DESTINATION" => "staging", "KAMAL_LOCK" => "false" },
                 hook_env.slice("KAMAL_COMMAND", "KAMAL_SUBCOMMAND", "KAMAL_VERSION", "KAMAL_DESTINATION", "KAMAL_LOCK"))
  end

  # Without --skip-hooks reaching Kamal the pre-connect hook would run here, as it does above.
  def test_skip_hooks_reaches_kamal_and_a_connection_failure_is_reported_like_kamal
    stdout, stderr, status = push("-c", "etc/kamal/deploy.yml", "--version=release-1", "--skip-hooks")

    assert_equal 1, status.exitstatus, stdout + stderr
    refute File.exist?(@hook_env), "the pre-connect hook ran despite --skip-hooks"
    assert_includes stdout, "mkdir -p .kamal on 127.0.0.1"
    assert_includes stderr, "ERROR (Errno::ECONNREFUSED): Exception while executing on host 127.0.0.1"
  end

  def test_usage_errors_exit_64_before_kamal_runs
    [
      ["-c", "etc/kamal/deploy.yml"],
      ["--version=release-1"],
      ["-c", "etc/kamal/deploy.yml", "--version=release-1", "extra"],
      ["-c", "etc/kamal/deploy.yml", "--version=release-1", "--roles=web"]
    ].each do |args|
      _stdout, stderr, status = push(*args)
      assert_equal 64, status.exitstatus, args.inspect
      assert_includes stderr, "usage: ci-deploy-push-env -c CONFIG [-d DESTINATION] --version=VERSION [--skip-hooks]"
    end
    refute File.exist?(@hook_env)
  end

  def test_needs_the_bundle_from_the_setup_action
    _stdout, stderr, status = push("-c", "etc/kamal/deploy.yml", "--version=release-1", env: { "BUNDLE_GEMFILE" => nil })
    assert_equal 1, status.exitstatus
    assert_includes stderr, "BUNDLE_GEMFILE is not set; run the setup action first"
  end

  # The command is added to Kamal's app CLI, hidden from its help. Kamal itself must not ship one
  # by that name: a Kamal release with the upstream fix replaces this script (design record 0002).
  def test_boot_env_is_registered_on_kamals_app_cli_and_hidden
    probe = <<~RUBY
      require "bundler/setup"
      require "kamal"
      require "json"
      shipped = Kamal::Cli::App.all_commands.key?("boot_env")
      load #{SCRIPT.inspect}
      CiDeploy::PushEnv.define_command!
      command = Kamal::Cli::App.all_commands["boot_env"]
      listed = Kamal::Cli::App.printable_commands(true, false).flatten.join("\\n")
      puts JSON.generate(shipped: shipped, registered: !command.nil?, hidden: command&.hidden?, listed: listed.include?("boot_env"),
                         loaded_runs_nothing: !defined?(KAMAL) || !KAMAL.configured?)
    RUBY
    output, status = Open3.capture2e(clean_env("BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile")), RbConfig.ruby, "-e", probe,
                                     chdir: @project, **spawn_options)
    assert status.success?, output
    assert_equal({ "shipped" => false, "registered" => true, "hidden" => true, "listed" => false, "loaded_runs_nothing" => true },
                 JSON.parse(output.lines.last))
  end
end
