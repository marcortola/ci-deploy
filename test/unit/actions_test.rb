# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"

# Structural rules every composite action in this repository keeps.
class ActionsTest < Minitest::Test
  ACTIONS = Dir.glob(File.join(ROOT, "*/action.yml")).sort.to_h { |path| [File.basename(File.dirname(path)), YAML.safe_load_file(path)] }
  PINNED = /\A[\w.-]+\/[\w.\/-]+@[0-9a-f]{40}\z/

  def steps(name) = ACTIONS.fetch(name).dig("runs", "steps")
  def step(name, id_or_name) = steps(name).find { |s| s["id"] == id_or_name || s["name"] == id_or_name }

  def test_the_expected_actions_exist_and_are_composite
    assert_equal %w[dependabot-merge deploy operations revision-check setup], ACTIONS.keys
    ACTIONS.each { |name, action| assert_equal "composite", action.dig("runs", "using"), name }
  end

  def test_third_party_actions_are_pinned_to_a_full_sha_with_a_release_comment
    ACTIONS.each_key do |name|
      text = File.read(File.join(ROOT, name, "action.yml"))
      text.scan(/^\s*(?:-\s+)?uses:\s*(\S+)(.*)$/).each do |ref, rest|
        refute ref.start_with?("./"), "#{name} uses a path in the consumer's checkout: #{ref}"
        assert_match PINNED, ref, "#{name}: #{ref}"
        assert_match(/\A\s*#\s*v?\d/, rest, "#{name}: #{ref} has no release comment")
      end
    end
  end

  def test_no_expression_is_interpolated_into_a_script
    ACTIONS.each do |name, action|
      action.dig("runs", "steps").each do |s|
        next unless s["run"]

        refute_includes s["run"], "${{", "#{name}/#{s['name'] || s['id']} interpolates an expression into its script; pass it through env"
      end
    end
  end

  def test_scripts_come_from_this_revision_never_from_the_consumers_checkout
    ACTIONS.each do |name, action|
      action.dig("runs", "steps").each do |s|
        next unless s["run"]

        s["run"].scan(%r{"\$GITHUB_ACTION_PATH/\.\./([^"]+)"}).flatten.each do |path|
          assert File.file?(File.join(ROOT, path)), "#{name} runs #{path}, which does not exist"
        end
        assert_match(/\$GITHUB_ACTION_PATH|\A\s*(cd|ruby) /, s["run"], "#{name}/#{s['name']} runs something outside this revision")
      end
    end
  end

  def test_every_referenced_input_is_declared
    ACTIONS.each do |name, action|
      declared = (action["inputs"] || {}).keys
      File.read(File.join(ROOT, name, "action.yml")).scan(/inputs\.([a-z0-9-]+)/).flatten.uniq.each do |input|
        assert_includes declared, input, "#{name} references undeclared input #{input}"
      end
    end
  end

  def test_deploy_cleanup_and_reporting_run_after_a_failure_and_the_result_is_re_raised_last
    deploy = step("deploy", "deploy")
    assert_equal true, deploy["continue-on-error"]
    names = steps("deploy").map { |s| s["name"] }
    index = names.index(deploy["name"])
    after = steps("deploy").drop(index + 1)
    assert_equal ["Clean up after the deploy", "Report the deploy outcome", "Re-raise the deploy result"], after.map { |s| s["name"] }
    after.each { |s| assert s["if"].to_s.start_with?("always()"), "#{s['name']} must run after a failure" }
    assert_includes after.last["run"], " finish"
    assert_equal "${{ steps.deploy.outputs.deploy-result }}", after.last.dig("env", "CI_DEPLOY_IN_RESULT")
  end

  # GitHub skips the deploy action (and its reporting) when setup fails, so setup reports a
  # failure itself, last, only after a failed step and only when told what it deploys.
  def test_setup_reports_its_own_failure_last_and_only_when_configured
    report = steps("setup").last
    assert_equal "Report a setup failure", report["name"]
    assert_equal "failure() && (inputs.report-destination != '' || inputs.report-environment-name != '')", report["if"]
    assert_equal true, report["continue-on-error"]
    assert_equal 'ruby "$GITHUB_ACTION_PATH/../bin/ci-deploy" report-setup-failure', report["run"]
    assert_equal({ "CI_DEPLOY_IN_REPORT_DESTINATION" => "${{ inputs.report-destination }}",
                   "CI_DEPLOY_IN_REPORT_ENVIRONMENT_NAME" => "${{ inputs.report-environment-name }}",
                   "CI_DEPLOY_IN_ROLLBAR_TOKEN" => "${{ inputs.rollbar-token }}",
                   "CI_DEPLOY_IN_SECRETS" => "${{ inputs.secrets }}" }, report["env"])
    inputs = ACTIONS["setup"]["inputs"]
    %w[report-destination report-environment-name rollbar-token].each do |name|
      assert_equal "", inputs.dig(name, "default"), name
      refute inputs.dig(name, "required"), name
    end
    steps("setup")[0...-1].each { |s| refute s["if"].to_s.match?(/always\(\)|failure\(\)/), "#{s['name']} runs after a failure" }
  end

  def test_deploy_and_operations_check_they_run_the_setup_revision
    assert_equal "${{ github.action_path }}/..", step("deploy", "deploy").dig("env", "CI_DEPLOY_ACTION_HOME")
    ops = steps("operations").find { |s| s["run"] }
    assert_equal "${{ github.action_path }}/..", ops.dig("env", "CI_DEPLOY_ACTION_HOME")
  end

  def test_defaults_that_must_stay_safe
    deploy = ACTIONS["deploy"]["inputs"]
    assert_equal true, deploy.dig("rollback", "required")
    refute deploy["rollback"].key?("default"), "rollback must be chosen by every consumer"
    assert_equal "false", deploy.dig("skip-hooks", "default")
    assert_equal "enforce", deploy.dig("branch-policy", "default")
    assert_equal "", ACTIONS.dig("operations", "inputs", "container-mode", "default")
  end

  def test_dependabot_covers_every_action_directory
    config = YAML.safe_load_file(File.join(ROOT, ".github/dependabot.yml"))
    directories = config["updates"].select { |u| u["package-ecosystem"] == "github-actions" }.flat_map { |u| u["directories"] || [u["directory"]] }
    ACTIONS.each_key { |name| assert_includes directories, "/#{name}", "Dependabot does not scan #{name}/action.yml" }
    assert_includes directories, "/"
    assert(config["updates"].any? { |u| u["package-ecosystem"] == "bundler" })
  end
end
