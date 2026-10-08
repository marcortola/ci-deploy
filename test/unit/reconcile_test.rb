# frozen_string_literal: true

require_relative "../test_helper"

class ReconcileTest < Minitest::Test
  SCRIPT = File.join(ROOT, "bin/ci-deploy-reconcile-removed-roles")
  REMOTE = File.join(ROOT, "lib/sh/reconcile-removed-roles.remote")
  CONFIG = <<~YAML
    ---
    :roles:
    - web
    - worker_1
    :hosts:
    - 192.0.2.10
    - 192.0.2.11
    :primary_host: 192.0.2.10
    :version: incoming-v2
    :service_with_version: example-app-incoming-v2
  YAML

  def setup
    @stubs = TestSupport::Stubs.new(tmpdir)
    @stdin = File.join(tmpdir, "ssh-stdin")
    @stubs.add("ssh", %(cat >> "#{@stdin}"; exit "${SSH_STUB_STATUS:-0}"))
    kamal_config(CONFIG)
  end

  def kamal_config(text, status: 0)
    File.write(File.join(tmpdir, "config.yml"), text)
    @stubs.add("kamal", %(cat "#{File.join(tmpdir, 'config.yml')}"; exit #{status}))
  end

  def reconcile(*args, env: {})
    base = { "PATH" => @stubs.path, "SSH_USER" => "deploy", "KAMAL_VERSION" => "incoming-v2", "KAMAL_DESTINATION" => "production" }
    Open3.capture2e(clean_env(base.merge(env)), "sh", SCRIPT, *args, chdir: tmpdir, **spawn_options)
  end

  def test_reads_kamal_symbol_keys_and_reconciles_every_host
    output, status = reconcile
    assert status.success?, output
    assert_equal [["config", "-c", "./etc/kamal/deploy.yml", "-d", "production"]], @stubs.calls_to("kamal")
    ssh = @stubs.calls_to("ssh")
    assert_equal ["deploy@192.0.2.10", "deploy@192.0.2.11"], ssh.map { |call| call[-2] }
    assert_equal "sh -s 'example-app' 'production' 'web worker_1 '", ssh.first.last
    assert_equal File.read(REMOTE) * 2, File.read(@stdin)
  end

  def test_reads_plain_keys_too
    kamal_config(CONFIG.gsub(/^:/, ""))
    _output, status = reconcile
    assert status.success?
    assert_equal 2, @stubs.calls_to("ssh").size
  end

  def test_configuration_selector_and_defaults
    reconcile("-c", "./etc/kamal/deploy-production.yml")
    reconcile(env: { "CI_DEPLOY_HOOK_CONFIG" => "./svc/deploy.yml", "KAMAL_DESTINATION" => nil })
    assert_equal [["config", "-c", "./etc/kamal/deploy-production.yml"], ["config", "-c", "./svc/deploy.yml"]], @stubs.calls_to("kamal")
    assert_equal "sh -s 'example-app' '' 'web worker_1 '", @stubs.calls_to("ssh").last.last
  end

  def test_fail_safe_skips
    {
      "kamal config fails" => -> { kamal_config(CONFIG, status: 1) },
      "no roles" => -> { kamal_config(CONFIG.sub(/:roles:\n- web\n- worker_1\n/, "")) },
      "no hosts" => -> { kamal_config(CONFIG.sub(/:hosts:\n- 192.0.2.10\n- 192.0.2.11\n/, "")) },
      "service not ending in the version" => -> { kamal_config(CONFIG.sub("example-app-incoming-v2", "example-app-other")) }
    }.each do |label, arrange|
      arrange.call
      output, status = reconcile
      assert status.success?, label
      assert_includes output, "skipping", label
    end
    assert_empty @stubs.calls_to("ssh")
  end

  def test_skips_without_ssh_user_or_version
    [{ "SSH_USER" => nil }, { "KAMAL_VERSION" => nil }].each do |env|
      output, status = reconcile(env: env)
      assert status.success?
      assert_includes output, "unset; skipping"
    end
    assert_empty @stubs.calls
  end

  def test_an_ssh_failure_is_not_fatal
    output, status = reconcile(env: { "SSH_STUB_STATUS" => "255" })
    assert status.success?
    assert_includes output, "ssh failed (non-fatal)"
  end

  def run_remote(service, destination, roles, containers)
    stubs = TestSupport::Stubs.new(File.join(tmpdir, "remote"))
    File.write(File.join(tmpdir, "containers"), containers)
    stubs.add("docker", %(if [ "$1" = ps ]; then cat "#{File.join(tmpdir, 'containers')}"; fi))
    output, status = Open3.capture2e(clean_env("PATH" => stubs.path), "sh", REMOTE, service, destination, roles, **spawn_options)
    assert status.success?, output
    stubs.calls_to("docker")
  end

  def test_remote_removes_only_running_containers_of_removed_roles
    calls = run_remote("example-app", "production", "web worker_1 ",
                       "web example-app-web-production-v2\nworker_1 example-app-worker_1-production-v2\nworker_2 example-app-worker_2-production-v1\n")
    assert_equal ["ps", "--filter", "label=service=example-app", "--filter", "label=destination=production", "--format", '{{.Label "role"}} {{.Names}}'], calls.first
    assert_equal [["stop", "-t", "30", "example-app-worker_2-production-v1"], ["rm", "-f", "example-app-worker_2-production-v1"]], calls.drop(1)
  end

  def test_remote_without_destination_does_not_filter_by_it_and_role_prefixes_do_not_match
    calls = run_remote("example-app", "", "worker_1 ", "worker_10 example-app-worker_10\n")
    assert_equal ["ps", "--filter", "label=service=example-app", "--format", '{{.Label "role"}} {{.Names}}'], calls.first
    assert_equal ["rm", "-f", "example-app-worker_10"], calls.last
  end
end
