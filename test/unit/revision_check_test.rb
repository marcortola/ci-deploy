# frozen_string_literal: true

require_relative "../test_helper"

class RevisionCheckTest < Minitest::Test
  SHA = "1111111111111111111111111111111111111111"
  OTHER = "2222222222222222222222222222222222222222"

  # A git checkout: the check lists the files git knows about.
  def component
    @component ||= File.join(tmpdir, "component").tap do |dir|
      FileUtils.mkdir_p(File.join(dir, ".github/workflows"))
      system("git", "init", "-q", dir, exception: true)
    end
  end

  def write(path, content)
    full = File.join(component, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def workflow(action, ref, comment = " # v1.0.0")
    "jobs:\n  deploy:\n    steps:\n      - uses: marcortola/ci-deploy/#{action}@#{ref}#{comment}\n"
  end

  def check(**options)
    CiDeploy::RevisionCheck.new(component: component, **options).call
  end

  def test_one_sha_across_top_level_workflows_passes
    write(".github/workflows/deploy.yml", workflow("setup", SHA) + workflow("deploy", SHA))
    write(".github/workflows/ops.yaml", workflow("operations", SHA))
    result = check
    assert result.ok?, result.errors.join("\n")
    assert_equal SHA, result.sha
    assert_equal 3, result.references.size
  end

  def test_different_shas_fail_and_list_every_reference
    write(".github/workflows/deploy.yml", workflow("setup", SHA))
    write(".github/workflows/ops.yml", workflow("operations", OTHER))
    result = check
    refute result.ok?
    assert_nil result.sha
    error = result.errors.join("\n")
    assert_includes error, "2 different revisions"
    assert_includes error, ".github/workflows/deploy.yml:4 @ #{SHA}"
    assert_includes error, ".github/workflows/ops.yml:4 @ #{OTHER}"
  end

  def test_references_under_shared_are_rejected
    write(".github/workflows/deploy.yml", workflow("setup", SHA))
    write(".github/workflows/shared/build/action.yml", "runs:\n  steps:\n    - uses: marcortola/ci-deploy/deploy@#{SHA}\n")
    result = check
    refute result.ok?
    assert_includes result.errors.join("\n"), ".github/workflows/shared/build/action.yml:3 references marcortola/ci-deploy"
  end

  def test_references_anywhere_else_under_github_are_rejected
    write(".github/workflows/deploy.yml", workflow("setup", SHA))
    write(".github/actions/x/action.yml", "uses: marcortola/ci-deploy/deploy@#{SHA}\n")
    refute check.ok?
  end

  def test_tags_branches_and_short_shas_are_rejected
    %w[v1 main 1111111].each do |ref|
      write(".github/workflows/deploy.yml", workflow("setup", ref))
      result = check
      refute result.ok?, ref
      assert_includes result.errors.join("\n"), "not a full commit SHA"
    end
  end

  def test_whole_repository_reference_counts_too
    write(".github/workflows/deploy.yml", workflow("setup", SHA) + "  uses: marcortola/ci-deploy@#{OTHER}\n")
    refute check.ok?
  end

  def test_no_reference_fails
    write(".github/workflows/ci.yml", "jobs: {}\n")
    refute check.ok?
  end

  def test_disagreeing_release_comments_fail
    write(".github/workflows/deploy.yml", workflow("setup", SHA, " # v1.0.0") + workflow("deploy", SHA, " # v1.1.0"))
    result = check
    refute result.ok?
    assert_includes result.errors.join("\n"), "release comments"
  end

  def test_own_ref_must_match
    write(".github/workflows/deploy.yml", workflow("setup", SHA))
    assert check(own_ref: SHA).ok?
    result = check(own_ref: OTHER)
    refute result.ok?
    assert_includes result.errors.join("\n"), "this check runs at #{OTHER}"
  end

  def test_references_outside_github_are_rejected
    write(".github/workflows/deploy.yml", workflow("setup", SHA))
    write("scripts/deploy.sh", "gh workflow run x # marcortola/ci-deploy/deploy@#{SHA}\n")
    result = check
    refute result.ok?
    assert_includes result.errors.join("\n"), "scripts/deploy.sh:1 references marcortola/ci-deploy"
  end

  def test_tracked_files_are_scanned_and_ignored_ones_are_not
    write(".github/workflows/deploy.yml", workflow("setup", SHA))
    write(".gitignore", "vendor/\n")
    write("vendor/x/action.yml", "uses: marcortola/ci-deploy/deploy@#{OTHER}\n")
    assert check.ok?, check.errors.join("\n")

    write("docs/notes.md", "uses: marcortola/ci-deploy/deploy@#{SHA}\n")
    system("git", "-C", component, "add", "docs/notes.md", exception: true)
    refute check.ok?
  end

  def test_owner_and_repository_match_case_insensitively
    write(".github/workflows/deploy.yml", workflow("setup", SHA) + "      - uses: MarcOrtola/CI-Deploy/deploy@#{OTHER}\n")
    result = check
    refute result.ok?
    assert_includes result.errors.join("\n"), "2 different revisions"

    write(".github/workflows/deploy.yml", workflow("setup", SHA))
    write(".github/workflows/shared/x/action.yml", "uses: Marcortola/Ci-Deploy/deploy@#{SHA}\n")
    refute check.ok?
  end

  def test_a_directory_outside_git_fails
    dir = File.join(tmpdir, "plain")
    FileUtils.mkdir_p(File.join(dir, ".github/workflows"))
    File.write(File.join(dir, ".github/workflows/deploy.yml"), workflow("setup", SHA))
    result = CiDeploy::RevisionCheck.new(component: dir).call
    refute result.ok?
    assert_includes result.errors.join("\n"), "is not a git checkout"
  end

  def test_ref_from_action_path
    assert_equal SHA, CiDeploy::RevisionCheck.ref_from_action_path("/home/runner/work/_actions/marcortola/ci-deploy/#{SHA}/revision-check/..")
    assert_equal "", CiDeploy::RevisionCheck.ref_from_action_path("/home/runner/work/app/app/./revision-check/..")
    assert_equal "", CiDeploy::RevisionCheck.ref_from_action_path("/home/runner/work/_actions/marcortola/ci-deploy-fork/#{SHA}/x")
    assert_equal SHA, CiDeploy::RevisionCheck.ref_from_action_path("/home/runner/work/_actions/MarcOrtola/CI-Deploy/#{SHA}/revision-check/..")
  end

  def test_cli_derives_its_own_ref_from_the_action_path
    write(".github/workflows/deploy.yml", workflow("setup", SHA))
    env = { "CI_DEPLOY_IN_COMPONENT" => component,
            "CI_DEPLOY_ACTION_HOME" => "/home/runner/work/_actions/marcortola/ci-deploy/#{OTHER}/revision-check/.." }
    output, status = Open3.capture2e(clean_env(env), RbConfig.ruby, File.join(ROOT, "bin/ci-deploy"), "revision-check", **spawn_options)
    refute status.success?
    assert_includes output, "this check runs at #{OTHER}"

    env["CI_DEPLOY_ACTION_HOME"] = "/home/runner/work/_actions/marcortola/ci-deploy/#{SHA}/revision-check/.."
    output, status = Open3.capture2e(clean_env(env), RbConfig.ruby, File.join(ROOT, "bin/ci-deploy"), "revision-check", **spawn_options)
    assert status.success?, output
  end
end
