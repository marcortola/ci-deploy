# frozen_string_literal: true

require_relative "../test_helper"

class OperationsTest < Minitest::Test
  def argvs(**inputs) = CiDeploy::Operations.new(inputs).argvs

  def invalid(**inputs)
    assert_raises(CiDeploy::Operations::Invalid) { argvs(**inputs) }
  end

  def test_accessory_operations_need_a_named_target
    CiDeploy::Operations::ACCESSORY_VERBS.each do |verb|
      assert_equal [["accessory", verb, "db"]], argvs(operation: "accessory-#{verb}", target: "db")
    end
    assert_equal [%w[accessory reboot all]], argvs(operation: "accessory-reboot", target: "all")
    invalid(operation: "accessory-boot")
    invalid(operation: "accessory-boot", target: "db --hosts=x")
  end

  def test_host_exec_runs_on_the_primary_by_default_or_on_all_with_roles_and_hosts
    assert_equal [["server", "exec", "--primary", "df -h"]], argvs(operation: "host-exec", command: "df -h")
    assert_equal [["server", "exec", "--roles=web,worker", "--hosts=192.0.2.10", "uptime"]],
                 argvs(operation: "host-exec", command: "uptime", server: "all", roles: "web,worker", hosts: "192.0.2.10")
    invalid(operation: "host-exec")
    invalid(operation: "host-exec", command: "uptime", server: "some")
    invalid(operation: "host-exec", command: "uptime", roles: "web --primary")
  end

  def test_app_exec_needs_an_explicit_container_mode
    invalid(operation: "app-exec", command: "env")
    assert_equal [["app", "exec", "--primary", "env"]], argvs(operation: "app-exec", command: "env", "container-mode": "new-image")
    assert_equal [["app", "exec", "--primary", "--reuse", "env"]], argvs(operation: "app-exec", command: "env", "container-mode": "live-container")
  end

  def test_console_prefixes_the_stack_runner_and_requires_a_stack
    { "symfony" => "bin/console cache:pool:list", "node" => "node scripts/check.js", "python" => "python manage.py check" }.each do |stack, expected|
      command = expected.split(" ", 2).last
      assert_equal [["app", "exec", "--primary", expected]], argvs(operation: "console", command: command, stack: stack, "container-mode": "new-image")
    end
    invalid(operation: "console", command: "about", "container-mode": "new-image")
    invalid(operation: "console", command: "about", stack: "ruby", "container-mode": "new-image")
  end

  def test_logs_for_app_proxy_and_accessory_with_validated_filters
    assert_equal [["app", "logs", "-n", "200", "-s", "15m", "-g", "ERROR", "--roles=web"]],
                 argvs(operation: "logs", target: "app", lines: "200", since: "15m", grep: "ERROR", roles: "web")
    assert_equal [["proxy", "logs", "--hosts=192.0.2.10"]], argvs(operation: "logs", target: "proxy", hosts: "192.0.2.10")
    assert_equal [["accessory", "logs", "db", "-n", "50"]], argvs(operation: "logs", target: "db", lines: "50")
    invalid(operation: "logs", target: "app", lines: "-1")
    invalid(operation: "logs", target: "app", since: "1h; id")
    invalid(operation: "logs", target: "app", grep: "it's")
  end

  def test_proxy_details_reads_details_and_boot_config
    assert_equal [%w[proxy details], %w[proxy boot_config get]], argvs(operation: "proxy-details")
  end

  def test_proxy_reboot_and_restart_need_an_explicit_target
    invalid(operation: "proxy-reboot")
    invalid(operation: "proxy-restart")
    assert_equal [["proxy", "reboot", "-y", "--hosts=192.0.2.10,192.0.2.11"]], argvs(operation: "proxy-reboot", hosts: "192.0.2.10,192.0.2.11")
    assert_equal [%w[proxy reboot -y]], argvs(operation: "proxy-reboot", hosts: "all")
    assert_equal [["proxy", "restart", "--hosts=192.0.2.10"]], argvs(operation: "proxy-restart", hosts: "192.0.2.10")
  end

  def test_free_arguments_through_kamal_also_need_a_proxy_target
    assert_raises(CiDeploy::Operations::Invalid) { argvs(operation: "kamal", args: "proxy reboot -y") }
    assert_raises(CiDeploy::Operations::Invalid) { argvs(operation: "kamal", args: "kamal proxy upgrade") }
    assert_equal [%w[proxy reboot -y --hosts 192.0.2.10]], argvs(operation: "kamal", args: "proxy reboot -y --hosts 192.0.2.10")
    assert_equal [%w[proxy reboot -h192.0.2.10]], argvs(operation: "kamal", args: "proxy reboot -h192.0.2.10")
  end

  def test_stopping_or_removing_the_proxy_or_the_app_needs_an_explicit_target
    ["proxy stop", "proxy remove", "remove -y", "upgrade -y", "proxy upgrade", "--roles web proxy reboot -y", "-y remove"].each do |args|
      assert_raises(CiDeploy::Operations::Invalid, args) { argvs(operation: "kamal", args: args) }
    end
    assert_equal [%w[proxy stop --hosts=192.0.2.10]], argvs(operation: "kamal", args: "proxy stop --hosts=192.0.2.10")
    assert_equal [%w[remove -y -h 192.0.2.10]], argvs(operation: "kamal", args: "remove -y -h 192.0.2.10")
    assert_equal [%w[proxy boot]], argvs(operation: "kamal", args: "proxy boot")
  end

  def test_an_empty_hosts_or_roles_filter_is_refused
    ["proxy reboot -y --hosts=,", %(proxy reboot -y --hosts ""), "proxy reboot -y -h,", %(proxy reboot -y -h ""), "proxy reboot -y --hosts", "proxy reboot -y -h= ",
     "app details --roles=", %(app details -r ""), "app details --roles=, ,", "app details -r,"].each do |args|
      error = assert_raises(CiDeploy::Operations::Invalid, args) { argvs(operation: "kamal", args: args) }
      assert_includes error.message, "needs at least one value", args
    end
  end

  def test_an_empty_hosts_or_roles_input_item_is_refused_in_the_catalog
    [{ operation: "proxy-reboot", hosts: "," }, { operation: "proxy-reboot", hosts: " , " }, { operation: "host-exec", command: "uptime", hosts: "192.0.2.10," },
     { operation: "host-exec", command: "uptime", roles: "," }, { operation: "logs", target: "app", roles: "web,,worker" }].each do |inputs|
      invalid(**inputs)
    end
  end

  def test_free_arguments_are_split_like_words_and_never_interpreted
    assert_equal [["app", "exec", "echo $(id) `id`; rm -rf / | cat > x", ";", "&&", "$HOME"]],
                 argvs(operation: "kamal", args: %(kamal app exec 'echo $(id) `id`; rm -rf / | cat > x' \; '&&' '$HOME'))
  end

  def test_free_arguments_cannot_override_config_or_destination
    ["-c other.yml", "--config-file=other.yml", "-dproduction", "--destination production", "-d production"].each do |extra|
      assert_raises(CiDeploy::Operations::Invalid, extra) { argvs(operation: "kamal", args: "app details #{extra}") }
    end
  end

  def test_unbalanced_quotes_and_empty_arguments_are_refused
    invalid(operation: "kamal", args: "app exec 'unterminated")
    invalid(operation: "kamal", args: "  ")
  end

  def test_unknown_operation_is_refused
    invalid(operation: "deploy")
  end
end

# The operation step end to end: the real CLI, Runner and argv handling, with a recording `kamal`.
class OperationCliTest < Minitest::Test
  def setup
    @stubs = TestSupport::Stubs.new(tmpdir)
    @stubs.add("kamal")
    @project = File.join(tmpdir, "project")
    FileUtils.mkdir_p(File.join(@project, "etc/kamal"))
    File.write(File.join(@project, "etc/kamal/deploy.yml"), "service: example\n")
  end

  def run_operation(inputs, extra_env = {})
    env = { "PATH" => @stubs.path, "CI_DEPLOY_HOME" => ROOT, "CI_DEPLOY_ACTION_HOME" => ROOT,
            "CI_DEPLOY_PROJECT_DIR" => @project, "CI_DEPLOY_CONFIG" => "etc/kamal/deploy.yml" }
    inputs.each { |name, value| env["CI_DEPLOY_IN_#{name.to_s.upcase.tr('-', '_')}"] = value }
    Open3.capture2e(clean_env(env.merge(extra_env)), RbConfig.ruby, File.join(ROOT, "bin/ci-deploy"), "operation", **spawn_options)
  end

  def test_shell_metacharacters_reach_kamal_as_literal_arguments
    marker = File.join(tmpdir, "pwned")
    args = %(app exec --reuse 'touch #{marker}; echo $(touch #{marker})' ; touch #{marker} '|' `touch #{marker}`)
    output, status = run_operation({ operation: "kamal", args: args, destination: "staging" })

    assert status.success?, output
    refute File.exist?(marker), "an argument was interpreted by a shell"
    assert_equal [["app", "exec", "--reuse", "touch #{marker}; echo $(touch #{marker})", ";", "touch", marker, "|",
                   "`touch", "#{marker}`", "-c", "etc/kamal/deploy.yml", "-d", "staging"]], @stubs.calls_to("kamal")
  end

  def test_a_metacharacter_command_input_is_one_argument
    marker = File.join(tmpdir, "pwned")
    output, status = run_operation({ operation: "host-exec", command: "uptime; touch #{marker}" })
    assert status.success?, output
    refute File.exist?(marker)
    assert_equal [["server", "exec", "--primary", "uptime; touch #{marker}", "-c", "etc/kamal/deploy.yml"]], @stubs.calls_to("kamal")
  end

  def test_proxy_reboot_without_target_runs_nothing
    output, status = run_operation({ operation: "proxy-reboot" })
    refute status.success?
    assert_includes output, "needs an explicit target"
    assert_empty @stubs.calls
  end

  def test_proxy_details_runs_both_reads
    _output, status = run_operation({ operation: "proxy-details", hosts: "192.0.2.10" })
    assert status.success?
    assert_equal [["proxy", "details", "--hosts=192.0.2.10", "-c", "etc/kamal/deploy.yml"],
                  ["proxy", "boot_config", "get", "--hosts=192.0.2.10", "-c", "etc/kamal/deploy.yml"]], @stubs.calls_to("kamal")
  end

  def test_a_failing_kamal_call_fails_the_step_and_stops
    @stubs.add("kamal", "exit 3")
    _output, status = run_operation({ operation: "proxy-details" })
    assert_equal 3, status.exitstatus
    assert_equal 1, @stubs.calls_to("kamal").size
  end

  def test_an_action_from_another_revision_is_refused
    other = File.join(tmpdir, "other-revision")
    FileUtils.mkdir_p(other)
    output, status = run_operation({ operation: "proxy-details" }, "CI_DEPLOY_ACTION_HOME" => other)
    refute status.success?
    assert_includes output, "pin every marcortola/ci-deploy action to the same SHA"
    assert_empty @stubs.calls
  end

  def test_config_input_selects_another_configuration_and_a_missing_one_is_an_error
    File.write(File.join(@project, "etc/kamal/deploy-production.yml"), "service: example\n")
    _output, status = run_operation({ operation: "proxy-details", config: "etc/kamal/deploy-production.yml" })
    assert status.success?
    assert_equal "etc/kamal/deploy-production.yml", @stubs.calls_to("kamal").first[-1]

    output, status = run_operation({ operation: "proxy-details", config: "etc/kamal/missing.yml" })
    refute status.success?
    assert_includes output, "etc/kamal/missing.yml not found"
  end
end
