# frozen_string_literal: true

require_relative "../test_helper"

class DeployTest < Minitest::Test
  SHA = "0123456789abcdef0123456789abcdef01234567"
  PREVIOUS = "fedcba9876543210fedcba9876543210fedcba98"
  MUTATING = %w[deploy rollback app\ boot app\ stop app\ remove proxy\ boot proxy\ reboot accessory server\ exec lock\ acquire].freeze

  def setup
    @gh = TestSupport::GithubFiles.new
    @runner = TestSupport::FakeRunner.new
    @runner.on(%w[git rev-parse HEAD], output: "#{SHA}\n")
    @runner.on(%w[git status --porcelain], output: "")
    @kamal = CiDeploy::Kamal.new(runner: @runner, config: "etc/kamal/deploy.yml", destination: "staging")
  end

  def teardown
    @gh.cleanup
  end

  def serving(*versions_by_host)
    { output: versions_by_host.map { |host, version| "App Host: #{host}\n#{version}\n\n" }.join }
  end

  def deploy(**options)
    outcome = nil
    capture_stdout { outcome = CiDeploy::Deploy.new(kamal: @kamal, runner: @runner, github: @gh.github, **options).call }
    outcome
  end

  def remote_mutations
    @runner.kamal_calls.select { |args| MUTATING.any? { |verb| args.join(" ").start_with?(verb) } }
  end

  def test_builds_and_deploys_one_version_with_config_and_destination
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))

    outcome = deploy

    assert outcome.success?
    assert_equal [
      ["app", "version", "-c", "etc/kamal/deploy.yml", "-d", "staging"],
      ["build", "push", "--version=#{SHA}", "-c", "etc/kamal/deploy.yml", "-d", "staging"],
      ["deploy", "--skip-push", "--version=#{SHA}", "-c", "etc/kamal/deploy.yml", "-d", "staging"]
    ], @runner.kamal_calls
    assert_equal({ "version" => SHA, "previous-version" => PREVIOUS, "deploy-result" => "success",
                   "rollback-result" => "not-needed", "image" => "" }, @gh.outputs)
  end

  def test_dirty_tree_version_is_drawn_once_and_shared_by_build_and_deploy
    @runner.on(%w[git status --porcelain], output: " M app.rb\n")
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))

    outcome = deploy

    versions = @runner.kamal_calls.filter_map { |args| args.find { |arg| arg.start_with?("--version=") } }
    assert_equal 2, versions.size
    assert_equal 1, versions.uniq.size, "build and deploy must name the same image"
    assert_match(/\A--version=#{SHA}_uncommitted_[0-9a-f]{16}\z/, versions.first)
    assert_equal outcome.version, versions.first.delete_prefix("--version=")
    assert_equal outcome.version, @gh.outputs["version"]
  end

  def test_explicit_version_is_used_for_build_and_deploy_without_reading_git
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))

    deploy(version: "release-42")

    refute(@runner.calls.any? { |argv| argv.first == "git" })
    assert_includes @runner.kamal_calls, ["build", "push", "--version=release-42", "-c", "etc/kamal/deploy.yml", "-d", "staging"]
    assert_includes @runner.kamal_calls, ["deploy", "--skip-push", "--version=release-42", "-c", "etc/kamal/deploy.yml", "-d", "staging"]
  end

  def test_explicit_version_that_is_not_an_image_tag_is_refused_before_any_kamal_call
    assert_raises(ArgumentError) { deploy(version: "v1; rm -rf /") }
    assert_empty @runner.kamal_calls
  end

  def test_without_a_git_checkout_and_without_a_version_nothing_runs
    @runner.on(%w[git rev-parse HEAD], status: 128, output: "fatal: not a git repository\n")
    assert_raises(ArgumentError) { deploy }
    assert_empty @runner.kamal_calls
  end

  def test_failed_build_blocks_every_remote_mutation
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))
    @runner.on(%w[kamal build push], status: 1, output: "ERROR: failed to solve\n")

    outcome = deploy(rollback: "auto")

    refute outcome.success?
    assert_equal "build-failed", outcome.deploy_result
    assert_empty remote_mutations
    assert_equal [%w[app version], %w[build push]], @runner.kamal_calls.map { |args| args.first(2) }
    assert_equal "build-failed", @gh.outputs["deploy-result"]
    assert_equal "not-attempted", @gh.outputs["rollback-result"]
    assert_equal "", @gh.outputs["previous-version"], "no rollback target is published before the image exists"
  end

  def test_skip_hooks_is_passed_to_the_deploy_only_and_warned
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))

    deploy(skip_hooks: true)

    assert_includes @runner.kamal_calls, ["deploy", "--skip-push", "--version=#{SHA}", "--skip-hooks", "-c", "etc/kamal/deploy.yml", "-d", "staging"]
    refute(@runner.kamal_calls.find { |args| args.first == "build" }.include?("--skip-hooks"))
    assert_includes @gh.log, "::warning::Deploying with --skip-hooks"
  end

  def prebuilt_config(image)
    { output: "---\n:service: example-app\n:absolute_image: #{image}\n" }
  end

  def test_prebuilt_mode_refuses_an_unpublished_image_without_touching_hosts
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))
    @runner.on(%w[kamal config], prebuilt_config("registry.example.com/example/app:release-7"))
    @runner.on(%w[docker manifest inspect], status: 1, output: "manifest unknown\n")

    outcome = deploy(mode: "prebuilt", version: "release-7", rollback: "auto")

    assert_equal "image-missing", outcome.deploy_result
    assert_empty remote_mutations
    refute(@runner.kamal_calls.any? { |args| args.first == "build" }, "prebuilt mode never builds")
    assert_includes @runner.calls, ["docker", "manifest", "inspect", "registry.example.com/example/app:release-7"]
    assert_includes @runner.kamal_calls, ["registry", "login", "--skip-remote", "-c", "etc/kamal/deploy.yml", "-d", "staging"]
    assert_equal "registry.example.com/example/app:release-7", @gh.outputs["image"]
    assert_equal "", @gh.outputs["previous-version"]
  end

  def test_prebuilt_mode_refuses_when_the_registry_login_fails
    @runner.on(%w[kamal config], prebuilt_config("registry.example.com/example/app:release-7"))
    @runner.on(%w[kamal registry login], status: 1)

    outcome = deploy(mode: "prebuilt", version: "release-7")

    assert_equal "image-missing", outcome.deploy_result
    assert_empty remote_mutations
    refute(@runner.calls.any? { |argv| argv.first == "docker" })
  end

  def test_prebuilt_mode_deploys_a_published_image_with_skip_push
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))
    @runner.on(%w[kamal config], prebuilt_config("127.0.0.1:5555/example/app:release-7"))

    outcome = deploy(mode: "prebuilt", version: "release-7")

    assert outcome.success?
    assert_includes @runner.calls, ["docker", "manifest", "inspect", "--insecure", "127.0.0.1:5555/example/app:release-7"]
    assert_includes @runner.kamal_calls, ["deploy", "--skip-push", "--version=release-7", "-c", "etc/kamal/deploy.yml", "-d", "staging"]
  end

  def test_invalid_mode_and_rollback_policy_are_refused
    assert_raises(ArgumentError) { deploy(mode: "docker") }
    assert_raises(ArgumentError) { deploy(rollback: "always") }
  end

  def test_failed_deploy_rolls_back_when_the_policy_is_auto_and_confirms_every_host
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS], ["192.0.2.11", PREVIOUS]))
    @runner.on(%w[kamal deploy], status: 1)

    outcome = deploy(rollback: "auto")

    assert_equal "deploy-failed", outcome.deploy_result
    assert_equal "succeeded", outcome.rollback_result
    assert_includes @runner.kamal_calls, ["rollback", PREVIOUS, "-c", "etc/kamal/deploy.yml", "-d", "staging"]
    assert_equal({ "deploy-result" => "deploy-failed", "rollback-result" => "succeeded" },
                 @gh.outputs.slice("deploy-result", "rollback-result"))
  end

  def test_failed_deploy_is_not_rolled_back_when_the_policy_is_off
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))
    @runner.on(%w[kamal deploy], status: 1)

    outcome = deploy(rollback: "off")

    assert_equal "disabled", outcome.rollback_result
    refute(@runner.kamal_calls.any? { |args| args.first == "rollback" })
    assert_equal PREVIOUS, @gh.outputs["previous-version"]
  end

  def test_rollback_policy_defaults_to_off
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))
    @runner.on(%w[kamal deploy], status: 1)

    assert_equal "disabled", deploy.rollback_result
  end

  def test_no_rollback_target_when_nothing_was_serving
    @runner.on(%w[kamal app version], serving(["192.0.2.10", ""]))
    @runner.on(%w[kamal deploy], status: 1)

    assert_equal "no-target", deploy(rollback: "auto").rollback_result
    refute(@runner.kamal_calls.any? { |args| args.first == "rollback" })
  end

  def test_no_rollback_target_when_the_version_query_fails
    @runner.on(%w[kamal app version], status: 1)
    @runner.on(%w[kamal deploy], status: 1)

    assert_equal "no-target", deploy(rollback: "auto").rollback_result
  end

  def test_the_version_being_deployed_is_never_its_own_rollback_target
    @runner.on(%w[kamal app version], serving(["192.0.2.10", SHA]))
    @runner.on(%w[kamal deploy], status: 1)

    assert_equal "no-target", deploy(rollback: "auto").rollback_result
    assert_equal "", @gh.outputs["previous-version"]
  end

  def test_a_replaced_container_is_never_a_rollback_target
    @runner.on(%w[kamal app version], serving(["192.0.2.10", "#{PREVIOUS}_replaced_0123456789abcdef"]))
    @runner.on(%w[kamal deploy], status: 1)

    assert_equal "no-target", deploy(rollback: "auto").rollback_result
  end

  def test_rollback_fails_when_the_previous_container_is_gone
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))
    @runner.on(%w[kamal deploy], status: 1)
    @runner.on(%w[kamal rollback], output: "#{PREVIOUS} is not available as a container on 192.0.2.10\n")

    outcome = deploy(rollback: "auto")

    assert_equal "failed", outcome.rollback_result
    assert_includes @gh.log, "is no longer on the host"
  end

  def test_rollback_fails_when_kamal_rollback_exits_non_zero
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))
    @runner.on(%w[kamal deploy], status: 1)
    @runner.on(%w[kamal rollback], status: 1)

    assert_equal "failed", deploy(rollback: "auto").rollback_result
  end

  def test_rollback_fails_unless_every_host_reports_the_previous_version
    @runner.on(%w[kamal app version],
               serving(["192.0.2.10", PREVIOUS], ["192.0.2.11", PREVIOUS]),
               serving(["192.0.2.10", PREVIOUS], ["192.0.2.11", SHA]))
    @runner.on(%w[kamal deploy], status: 1)

    assert_equal "failed", deploy(rollback: "auto").rollback_result
    assert_includes @gh.log, "is not in effect on every host"
  end

  def test_rollback_is_unconfirmed_when_the_version_cannot_be_read_afterwards
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]), { status: 1 })
    @runner.on(%w[kamal deploy], status: 1)

    assert_equal "failed", deploy(rollback: "auto").rollback_result
    assert_includes @gh.log, "unconfirmed"
  end
end

class DeployTest
  def test_before_deploy_command_runs_after_the_build_and_before_kamal_deploy_even_with_skip_hooks
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))

    deploy(before_deploy: %w[ci-deploy-host-control --command /usr/local/sbin/example-control pause], skip_hooks: true)

    order = @runner.calls.reject { |argv| argv.first == "git" }.map { |argv| argv.first(2) }
    assert_equal [%w[kamal app], %w[kamal build], %w[ci-deploy-host-control --command], %w[kamal deploy]], order
  end

  def test_before_deploy_command_does_not_run_when_the_build_fails
    @runner.on(%w[kamal build push], status: 1)
    deploy(before_deploy: %w[pause-tool])
    refute(@runner.calls.any? { |argv| argv.first == "pause-tool" })
  end

  def test_failed_before_deploy_command_stops_the_deploy
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))
    @runner.on(%w[pause-tool], status: 4)

    outcome = deploy(before_deploy: %w[pause-tool], rollback: "auto")

    assert_equal "before-deploy-failed", outcome.deploy_result
    assert_equal "not-attempted", outcome.rollback_result
    refute(@runner.kamal_calls.any? { |args| %w[deploy rollback].include?(args.first) })
  end
end

class DeployTest
  def test_before_deploy_command_receives_the_command_env
    @runner.on(%w[kamal app version], serving(["192.0.2.10", PREVIOUS]))

    deploy(before_deploy: %w[pause-tool], command_env: { "KAMAL_DESTINATION" => "staging" })

    index = @runner.calls.index { |argv| argv.first == "pause-tool" }
    refute_nil index
    assert_equal({ "KAMAL_DESTINATION" => "staging" }, @runner.envs[index])
  end
end
