# frozen_string_literal: true

require_relative "../test_helper"

class MetadataTest < Minitest::Test
  def setup = @gh = TestSupport::GithubFiles.new
  def teardown = @gh.cleanup

  def metadata(branch:, destination:, policy: "enforce")
    CiDeploy::Metadata.new(github: @gh.github, branch: branch, commit: "0123456789abcdef0123456789abcdef01234567",
                           destination: destination, policy: policy, clock: -> { Time.utc(2026, 1, 2, 3, 4, 5) })
  end

  def test_production_from_the_production_branch_is_allowed
    metadata(branch: "main", destination: "production").validate!
  end

  def test_no_destination_counts_as_production
    metadata(branch: "main", destination: "").validate!
    assert_raises(CiDeploy::Metadata::PolicyViolation) { metadata(branch: "feature", destination: "").validate! }
  end

  def test_production_from_another_branch_is_refused
    assert_raises(CiDeploy::Metadata::PolicyViolation) { metadata(branch: "develop", destination: "production").validate! }
  end

  def test_the_production_branch_is_refused_for_another_destination
    assert_raises(CiDeploy::Metadata::PolicyViolation) { metadata(branch: "main", destination: "staging").validate! }
  end

  def test_other_branches_may_deploy_to_other_destinations
    metadata(branch: "develop", destination: "staging").validate!
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

  def test_export_without_destination_names_production
    capture_stdout { metadata(branch: "main", destination: "").export }
    assert_equal "production", @gh.exported["DEPLOY_ENV"]
  end
end
