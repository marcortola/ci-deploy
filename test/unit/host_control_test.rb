# frozen_string_literal: true

require_relative "../test_helper"

# bin/ci-deploy-host-control: the parameterised form of a pause/resume control for a service that
# competes with a rollout, with a recording ssh.
class HostControlTest < Minitest::Test
  SCRIPT = File.join(ROOT, "bin/ci-deploy-host-control")
  COMMAND = "/usr/local/sbin/example-control"

  def setup
    @stubs = TestSupport::Stubs.new(tmpdir)
    @stubs.add("ssh", 'exit "${SSH_STUB_STATUS:-0}"')
  end

  def control(*args, env: {})
    base = { "PATH" => @stubs.path, "SSH_USER" => "deploy", "SERVER_IPS" => "192.0.2.10,192.0.2.11", "KAMAL_DESTINATION" => "production" }
    Open3.capture2e(clean_env(base.merge(env)), "sh", SCRIPT, *args, **spawn_options)
  end

  def ssh_calls = @stubs.calls_to("ssh")

  def test_runs_the_action_on_the_first_host_through_sudo
    output, status = control("--command", COMMAND, "pause")
    assert status.success?, output
    assert_equal [["-p", "22", "-o", "StrictHostKeyChecking=accept-new", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                   "deploy@192.0.2.10", "sudo -n #{COMMAND} pause"]], ssh_calls
  end

  def test_space_separated_hosts_custom_variable_port_and_no_sudo
    _output, status = control("--command", COMMAND, "--hosts-var", "TELEMETRY_HOSTS", "--no-sudo", "resume",
                              env: { "TELEMETRY_HOSTS" => " 192.0.2.20 192.0.2.21", "SSH_PORT" => "2222" })
    assert status.success?
    call = ssh_calls.first
    assert_equal ["-p", "2222"], call.first(2)
    assert_equal ["deploy@192.0.2.20", "#{COMMAND} resume"], call.last(2)
  end

  def test_other_destinations_exit_without_connecting
    _output, status = control("--command", COMMAND, "pause", env: { "KAMAL_DESTINATION" => "staging" })
    assert status.success?
    assert_empty ssh_calls
  end

  def test_no_destination_counts_as_the_first_listed_one
    _output, status = control("--command", COMMAND, "--destinations", "production,canary", "pause", env: { "KAMAL_DESTINATION" => nil })
    assert status.success?
    assert_equal 1, ssh_calls.size
  end

  def test_actions_outside_the_allowed_list_are_refused
    output, status = control("--command", COMMAND, "--actions", "pause,resume", "verify")
    assert_equal 64, status.exitstatus
    assert_includes output, "not one of: pause,resume"
    output, status = control("--command", COMMAND, "pause;id")
    assert_equal 64, status.exitstatus, output
    assert_empty ssh_calls
  end

  def test_the_command_must_be_a_plain_absolute_path
    [["relative/control"], ["/usr/local/sbin/x;id"], ["/usr/local/sbin/x $(id)"], []].each do |command|
      _output, status = control(*(command.empty? ? [] : ["--command", *command]), "pause")
      assert_equal 64, status.exitstatus, command.inspect
    end
    assert_empty ssh_calls
  end

  def test_a_missing_or_unsafe_host_is_an_error
    [nil, "", "192.0.2.10;id", "$(id)"].each do |hosts|
      _output, status = control("--command", COMMAND, "pause", env: { "SERVER_IPS" => hosts })
      assert_equal 1, status.exitstatus, hosts.inspect
    end
    assert_empty ssh_calls
  end

  def test_ssh_user_is_required
    _output, status = control("--command", COMMAND, "pause", env: { "SSH_USER" => nil })
    refute status.success?
    assert_empty ssh_calls
  end

  def test_the_remote_status_is_returned_to_the_caller
    _output, status = control("--command", COMMAND, "pause", env: { "SSH_STUB_STATUS" => "5" })
    assert_equal 5, status.exitstatus
  end

  # The recovery path: the deploy action's cleanup command resumes the service after a failed
  # deploy; a failed resume only warns, and the deploy's own failure is what the job reports.
  def test_resume_as_the_cleanup_command_after_a_failed_deploy
    gh = TestSupport::GithubFiles.new
    project = File.join(tmpdir, "project")
    FileUtils.mkdir_p(project)
    env = gh.env.merge("PATH" => "#{File.join(ROOT, 'bin')}:#{@stubs.path}", "CI_DEPLOY_PROJECT_DIR" => project,
                       "SSH_USER" => "deploy", "SERVER_IPS" => "192.0.2.10", "KAMAL_DESTINATION" => "production",
                       "SSH_STUB_STATUS" => "1",
                       "CI_DEPLOY_IN_CLEANUP_COMMAND" => "ci-deploy-host-control --command #{COMMAND} resume")
    output, status = Open3.capture2e(clean_env(env), RbConfig.ruby, File.join(ROOT, "bin/ci-deploy"), "cleanup", **spawn_options)
    assert status.success?, output
    assert_includes output, "the deploy result is unchanged"
    assert_equal "sudo -n #{COMMAND} resume", ssh_calls.first.last

    output, status = Open3.capture2e(clean_env(env.merge("CI_DEPLOY_IN_RESULT" => "deploy-failed")), RbConfig.ruby,
                                     File.join(ROOT, "bin/ci-deploy"), "finish", **spawn_options)
    refute status.success?
    assert_includes output, "'deploy-failed'"
  ensure
    gh&.cleanup
  end
end
