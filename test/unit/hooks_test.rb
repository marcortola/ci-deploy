# frozen_string_literal: true

require_relative "../test_helper"

# Example consumer hooks (test/fixtures/hooks) running against lib/sh/hooks.sh with a recording
# kamal that fails, with status 37, when its last argument is HOOK_FAIL_COMMAND.
class HooksTest < Minitest::Test
  HOOKS = File.join(TestSupport::FIXTURES, "hooks")

  def setup
    @project = File.join(tmpdir, "project")
    FileUtils.mkdir_p(@project)
    @stubs = TestSupport::Stubs.new(tmpdir)
    @stubs.add("kamal", <<~'SH')
      for last in "$@"; do :; done
      if [ -n "${HOOK_FAIL_COMMAND:-}" ] && [ "$last" = "$HOOK_FAIL_COMMAND" ]; then
          failures=$(cat "$0.failures" 2>/dev/null || echo 0)
          if [ -n "${HOOK_FAIL_TIMES:-}" ] && [ "$failures" -ge "$HOOK_FAIL_TIMES" ]; then exit 0; fi
          echo $((failures + 1)) > "$0.failures"
          exit 37
      fi
    SH
    @stubs.add("ci-deploy-reconcile-removed-roles")
  end

  def hook(stack, name, env = {})
    base = { "PATH" => @stubs.path, "CI_DEPLOY_HOOKS_LIB" => File.join(ROOT, "lib/sh"), "KAMAL_VERSION" => "incoming-v2",
             "KAMAL_DESTINATION" => "production", "KAMAL_COMMAND" => "deploy" }
    Open3.capture2e(clean_env(base.merge(env)), "sh", File.join(HOOKS, stack, name), chdir: @project, **spawn_options)
  end

  def exec_prefix(config: "./etc/kamal/deploy.yml", destination: "production", roles: "web", reuse: false)
    ["app", "exec", "--primary", *("--reuse" if reuse), *("--roles=#{roles}" if roles), "-c", config,
     *(["-d", destination] if destination), "--version", "incoming-v2"]
  end

  def test_symfony_pre_deploy_runs_migrations_first_from_the_incoming_image
    output, status = hook("symfony", "pre-deploy")
    assert status.success?, output
    assert_equal [[*exec_prefix, "bin/console doctrine:migrations:migrate -n -v"],
                  [*exec_prefix, "bin/console app:messaging:setup"]], @stubs.calls_to("kamal")
  end

  def test_the_setup_actions_configuration_is_used_by_default
    _output, status = hook("symfony", "pre-deploy", "CI_DEPLOY_CONFIG" => "etc/kamal/deploy.yml")
    assert status.success?
    assert_equal exec_prefix(config: "etc/kamal/deploy.yml"), @stubs.calls_to("kamal").first[0..-2]
  end

  def test_a_failed_migration_fails_the_hook_and_stops_every_later_task
    output, status = hook("symfony", "pre-deploy", "HOOK_FAIL_COMMAND" => "bin/console doctrine:migrations:migrate -n -v")
    assert_equal 37, status.exitstatus, output
    assert_equal 1, @stubs.calls_to("kamal").size
  end

  def test_a_failure_in_a_later_task_still_fails_the_hook
    _output, status = hook("symfony", "pre-deploy", "HOOK_FAIL_COMMAND" => "bin/console app:messaging:setup")
    assert_equal 37, status.exitstatus
    assert_equal 2, @stubs.calls_to("kamal").size
  end

  def test_rollback_changes_no_schema_and_runs_no_maintenance
    %w[pre-deploy post-deploy].each do |name|
      _output, status = hook("symfony", name, "KAMAL_COMMAND" => "rollback")
      assert status.success?
    end
    assert_empty @stubs.calls
  end

  def test_symfony_post_deploy_reconciles_first_then_runs_maintenance_in_order
    output, status = hook("symfony", "post-deploy")
    assert status.success?, output
    assert_equal ["ci-deploy-reconcile-removed-roles", "kamal", "kamal"], @stubs.calls.map(&:first)
    assert_equal ["bin/console app:messaging:prune --force", "bin/console app:search:reindex --batch-size=100"],
                 @stubs.calls_to("kamal").map(&:last)
  end

  def test_a_failed_reconcile_does_not_fail_the_post_deploy
    @stubs.add("ci-deploy-reconcile-removed-roles", "exit 1")
    _output, status = hook("symfony", "post-deploy")
    assert status.success?
    assert_equal 2, @stubs.calls_to("kamal").size
  end

  def test_node_live_container_reuses_the_running_container_and_new_image_does_not
    output, status = hook("node", "post-deploy", "KAMAL_DESTINATION" => "staging")
    assert status.success?, output
    assert_equal [[*exec_prefix(destination: "staging", reuse: true), "npm run db:migrate"],
                  [*exec_prefix(destination: "staging"), "node dist/bin/verify.js"]], @stubs.calls_to("kamal")
  end

  def test_node_best_effort_verification_only_warns
    output, status = hook("node", "post-deploy", "HOOK_FAIL_COMMAND" => "node dist/bin/verify.js")
    assert status.success?
    assert_includes output, "::warning::verification failed"
  end

  def test_python_without_roles_or_destination_and_with_its_own_configuration
    output, status = hook("python", "pre-deploy", "KAMAL_DESTINATION" => nil)
    assert status.success?, output
    assert_equal [[*exec_prefix(config: "./services/api/etc/kamal/deploy-production.yml", destination: nil, roles: nil),
                   "python manage.py migrate --noinput"]], @stubs.calls_to("kamal")
  end

  def test_python_retries_a_failing_command_then_gives_up
    output, status = hook("python", "pre-deploy", "HOOK_FAIL_COMMAND" => "python manage.py migrate --noinput")
    refute status.success?
    assert_equal 3, @stubs.calls_to("kamal").size
    assert_includes output, "attempt 2/3 failed"
  end

  def test_python_retry_stops_at_the_first_success
    _output, status = hook("python", "pre-deploy", "HOOK_FAIL_COMMAND" => "python manage.py migrate --noinput", "HOOK_FAIL_TIMES" => "1")
    assert status.success?
    assert_equal 2, @stubs.calls_to("kamal").size
  end

  def run_helper(script, env = {})
    base = { "PATH" => @stubs.path, "KAMAL_VERSION" => "incoming-v2" }
    Open3.capture2e(clean_env(base.merge(env)), "sh", "-c", ". \"#{ROOT}/lib/sh/hooks.sh\"; #{script}", chdir: @project, **spawn_options)
  end

  def test_the_container_mode_is_never_defaulted
    ["ci_deploy_exec '' 'env'", "ci_deploy_exec reuse 'env'", "ci_deploy_symfony 'about'"].each do |script|
      output, status = run_helper(script)
      assert_equal 64, status.exitstatus, script
      assert_includes output, "choose the container explicitly"
    end
    assert_empty @stubs.calls
  end

  def test_the_incoming_version_is_required
    output, status = run_helper("ci_deploy_exec new-image env", "KAMAL_VERSION" => nil)
    assert_equal 64, status.exitstatus
    assert_includes output, "KAMAL_VERSION is required"
    assert_empty @stubs.calls
  end

  def test_an_empty_command_is_refused
    _output, status = run_helper("ci_deploy_exec new-image ''")
    assert_equal 64, status.exitstatus
  end

  def test_the_command_reaches_kamal_as_one_argument
    _output, status = run_helper("ci_deploy_exec new-image 'echo $(id); ls | wc -l'")
    assert status.success?
    assert_equal "echo $(id); ls | wc -l", @stubs.calls_to("kamal").first.last
  end
end
