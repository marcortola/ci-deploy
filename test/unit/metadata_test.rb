# frozen_string_literal: true

require_relative "../test_helper"

class MetadataTest < Minitest::Test
  def setup = @gh = TestSupport::GithubFiles.new
  def teardown = @gh.cleanup

  def metadata(branch:, destination:, policy: "enforce", **names)
    CiDeploy::Metadata.new(github: @gh.github, branch: branch, commit: "0123456789abcdef0123456789abcdef01234567",
                           destination: destination, policy: policy, clock: -> { Time.utc(2026, 1, 2, 3, 4, 5) }, **names)
  end

  def refusal(**args)
    assert_raises(CiDeploy::Metadata::PolicyViolation) { metadata(**args).validate! }.message
  end

  def test_production_from_the_production_branch_is_allowed
    metadata(branch: "main", destination: "production").validate!
  end

  def test_no_destination_counts_as_production
    metadata(branch: "main", destination: "").validate!
    assert_raises(CiDeploy::Metadata::PolicyViolation) { metadata(branch: "feature", destination: "").validate! }
  end

  def test_no_destination_from_a_feature_branch_is_refused_as_production
    assert_equal "Production deployments are only allowed from the 'main' branch, not 'feature/login'.",
                 refusal(branch: "feature/login", destination: "")
  end

  def test_production_from_another_branch_is_refused
    assert_raises(CiDeploy::Metadata::PolicyViolation) { metadata(branch: "develop", destination: "production").validate! }
  end

  def test_production_from_a_feature_branch_is_refused
    assert_equal "Production deployments are only allowed from the 'main' branch, not 'feature/login'.",
                 refusal(branch: "feature/login", destination: "production")
  end

  # Staging is reset to the production branch on demand, so enforce only guards production.
  def test_the_production_branch_may_deploy_to_another_destination
    metadata(branch: "main", destination: "staging").validate!
  end

  def test_other_branches_may_deploy_to_other_destinations
    metadata(branch: "develop", destination: "staging").validate!
  end

  def test_a_feature_branch_may_deploy_to_staging
    metadata(branch: "feature/login", destination: "staging").validate!
  end

  def test_custom_production_names_guard_their_own_production
    names = { production_branch: "release", production_destination: "live" }
    metadata(branch: "release", destination: "live", **names).validate!
    metadata(branch: "release", destination: "", **names).validate!
    assert_equal "Production deployments are only allowed from the 'release' branch, not 'main'.",
                 refusal(branch: "main", destination: "live", **names)
    assert_equal "Production deployments are only allowed from the 'release' branch, not 'feature/login'.",
                 refusal(branch: "feature/login", destination: "", **names)
  end

  def test_custom_production_names_allow_other_destinations_from_any_branch
    names = { production_branch: "release", production_destination: "live" }
    metadata(branch: "release", destination: "staging", **names).validate!
    metadata(branch: "feature/login", destination: "staging", **names).validate!
    metadata(branch: "main", destination: "production", **names).validate!
  end

  def test_policy_off_allows_any_pairing
    metadata(branch: "develop", destination: "production", policy: "off").validate!
  end

  def test_unknown_policy_is_refused
    assert_raises(ArgumentError) { metadata(branch: "main", destination: "", policy: "warn") }
  end

  def test_export_writes_the_deploy_metadata
    capture_stdout { metadata(branch: "develop", destination: "staging").export }
    assert_equal({ "GIT_BRANCH" => "develop", "GIT_COMMIT" => "0123456789abcdef0123456789abcdef01234567",
                   "GIT_COMMIT_SHORT" => "0123456", "DEPLOY_TIMESTAMP" => "2026-01-02T03:04:05Z",
                   "DEPLOY_ENV" => "staging" }, @gh.exported)
  end

  def test_export_from_the_production_branch_to_staging_names_staging
    capture_stdout { metadata(branch: "main", destination: "staging").export }
    assert_equal "main", @gh.exported["GIT_BRANCH"]
    assert_equal "staging", @gh.exported["DEPLOY_ENV"]
  end

  def test_export_without_destination_names_production
    capture_stdout { metadata(branch: "main", destination: "").export }
    assert_equal "production", @gh.exported["DEPLOY_ENV"]
  end
end
