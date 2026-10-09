# frozen_string_literal: true

require_relative "../test_helper"

# The shared scripts behind the dependabot-merge and setup actions, with a recording stub for gh.
class DependabotMergeTest < Minitest::Test
  SCRIPT = File.join(ROOT, "lib/sh/dependabot-merge.sh")

  def setup
    @stubs = TestSupport::Stubs.new(tmpdir)
    @stubs.add("gh", 'if [ "$1" = api ]; then echo "${ALERTS:-1}"; fi')
  end

  def merge(deps, env = {})
    base = { "PATH" => @stubs.path, "DEPS" => JSON.generate(deps), "GH_REPO" => "example/app", "PR_URL" => "https://github.example/pr/1",
             "HEAD_SHA" => "abc", "DEFAULT_BRANCH" => "main" }
    Open3.capture2e(clean_env(base.merge(env)), "bash", SCRIPT, **spawn_options)
  end

  def dep(prev, new, name = "example/lib") = { "dependencyName" => name, "prevVersion" => prev, "newVersion" => new }

  def test_caret_range_update_with_an_open_alert_is_merged_and_deploy_dispatched
    output, status = merge([dep("v1.2.3", "1.4.0")], "DEPLOY_WORKFLOW" => "deploy.yml")
    assert status.success?, output
    calls = @stubs.calls_to("gh")
    assert_equal ["api", "-X", "GET", "repos/example/app/dependabot/alerts", "-f", "state=open", "-f", "package=example/lib", "--jq", "length"], calls[0]
    assert_equal ["pr", "merge", "https://github.example/pr/1", "--squash", "--match-head-commit", "abc"], calls[1]
    assert_equal ["workflow", "run", "deploy.yml", "--ref", "main"], calls[2]
  end

  def test_without_a_deploy_workflow_nothing_is_dispatched
    merge([dep("0.3.1", "0.3.9")])
    assert_equal %w[api pr], @stubs.calls_to("gh").map(&:first)
  end

  def test_held_for_review
    {
      "major bump" => [[dep("1.9.0", "2.0.0")], {}],
      "0.x minor bump" => [[dep("0.3.1", "0.4.0")], {}],
      "0.0.x" => [[dep("0.0.1", "0.0.2")], {}],
      "unparseable" => [[dep("main", "dev-main")], {}],
      "empty" => [[], {}],
      "one of several outside the range" => [[dep("1.0.0", "1.1.0"), dep("2.0.0", "3.0.0", "other")], {}],
      "grouped" => [[dep("1.0.0", "1.1.0")], { "DEPENDENCY_GROUP" => "weekly" }],
      "github actions" => [[dep("1.0.0", "1.1.0")], { "ECOSYSTEM" => "github_actions" }]
    }.each do |label, (deps, env)|
      output, status = merge(deps, env)
      assert status.success?, label
      assert_includes output, "Held for review", label
      refute(@stubs.calls_to("gh").any? { |call| call.first == "pr" }, label)
    end
  end

  def test_no_open_alert_is_held_for_review
    output, status = merge([dep("1.0.0", "1.0.1")], "ALERTS" => "0")
    assert status.success?
    assert_includes output, "no open Dependabot alert"
    refute(@stubs.calls_to("gh").any? { |call| call.first == "pr" })
  end
end

class SetupPathsTest < Minitest::Test
  SCRIPT = File.join(ROOT, "lib/sh/setup-paths.sh")

  def setup
    @gh = TestSupport::GithubFiles.new
    @workspace = File.join(tmpdir, "workspace")
    FileUtils.mkdir_p(File.join(@workspace, "services/api/etc/kamal"))
    File.write(File.join(@workspace, "services/api/etc/kamal/deploy-production.yml"), "service: example\n")
  end

  def teardown = @gh.cleanup

  def setup_paths(project, config)
    env = @gh.env.merge("GITHUB_ACTION_PATH" => File.join(ROOT, "setup"), "GITHUB_WORKSPACE" => @workspace,
                        "PROJECT_DIRECTORY" => project, "CONFIG" => config)
    Open3.capture2e(clean_env(env), "sh", SCRIPT, **spawn_options)
  end

  def test_records_this_revision_and_the_project
    output, status = setup_paths("services/api", "etc/kamal/deploy-production.yml")
    assert status.success?, output
    home = File.realpath(ROOT)
    project = File.realpath(File.join(@workspace, "services/api"))
    exported = @gh.exported
    assert_equal home, exported["CI_DEPLOY_HOME"]
    assert_equal "#{home}/lib/sh", exported["CI_DEPLOY_HOOKS_LIB"]
    assert_equal project, exported["CI_DEPLOY_PROJECT_DIR"]
    assert_equal "etc/kamal/deploy-production.yml", exported["CI_DEPLOY_CONFIG"]
    assert_equal "#{home}/Gemfile", exported["BUNDLE_GEMFILE"]
    assert exported["RUBYLIB"].start_with?("#{home}/lib")
    assert_equal "#{home}/bin\n", File.read(@gh.env["GITHUB_PATH"])
    assert_equal({ "home" => home, "project-directory" => project }, @gh.outputs)
  end

  def test_a_missing_project_or_configuration_fails
    output, status = setup_paths("services/missing", "etc/kamal/deploy.yml")
    refute status.success?
    assert_includes output, "project-directory 'services/missing' does not exist"
    output, status = setup_paths("services/api", "etc/kamal/deploy.yml")
    refute status.success?
    assert_includes output, "Kamal configuration 'etc/kamal/deploy.yml' not found"
  end

  def test_multiline_paths_are_refused
    _output, status = setup_paths("services/api\nINJECTED=1", "etc/kamal/deploy-production.yml")
    refute status.success?
    assert_empty @gh.exported
  end
end

# script/check-remote-pin, run from a copy inside a scratch repository.
class CheckRemotePinTest < Minitest::Test
  GIT_ENV = { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.com", "GIT_COMMITTER_NAME" => "t",
              "GIT_COMMITTER_EMAIL" => "t@example.com", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1" }.freeze

  def setup
    @repo = File.join(tmpdir, "repo")
    write("script/check-remote-pin", File.read(File.join(ROOT, "script/check-remote-pin")))
    write("deploy/action.yml", "name: deploy\n")
    write("lib/ci_deploy/x.rb", "# v1\n")
    write("Gemfile.lock", "kamal (2.10.0)\n")
    git("init", "-q")
    @code = commit("action code")
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
    File.write(File.join(@repo, path), content)
  end

  def git(*args)
    output, status = Open3.capture2e(clean_env(GIT_ENV), "git", *args, chdir: @repo, **spawn_options)
    assert status.success?, output
    output
  end

  def commit(message)
    git("add", "-A")
    git("commit", "-q", "-m", message)
    git("rev-parse", "HEAD").strip
  end

  def pin_workflow(*shas)
    write(".github/workflows/remote-consumer.yml",
          shas.map { |sha| "      - uses: marcortola/ci-deploy/deploy@#{sha} # pin\n" }.join)
    commit("pin")
  end

  def check
    Open3.capture2e(clean_env(GIT_ENV), "sh", File.join(@repo, "script/check-remote-pin"), **spawn_options)
  end

  def test_a_pin_with_the_same_action_code_passes
    pin_workflow(@code)
    write("docs/notes.md", "docs only\n")
    commit("docs")
    output, status = check
    assert status.success?, output
    assert_includes output, "pins #{@code}"
  end

  def test_changed_action_code_after_the_pin_fails
    pin_workflow(@code)
    { "lib/ci_deploy/x.rb" => "# v2\n", "Gemfile.lock" => "kamal (2.10.1)\n", "deploy/action.yml" => "name: changed\n" }.each do |path, content|
      write(path, content)
      commit(path)
      output, status = check
      refute status.success?, path
      assert_includes output, "differs from the pinned #{@code}"
      assert_includes output, path
    end
  end

  # The compared paths are derived, never listed: every directory, at any depth, holding an
  # action.yml at HEAD or at the pin, so an action added or removed after the pin is caught too.
  def test_an_action_added_or_removed_after_the_pin_fails
    pin_workflow(@code)
    write("new-action/action.yml", "name: new\n")
    write("new-action/README.md", "docs\n")
    commit("new action")
    output, status = check
    refute status.success?, output
    assert_includes output, "new-action/action.yml"

    commit_pin_to_head
    write("new-action/run.sh", "echo changed\n")
    commit("change beside the new action")
    output, status = check
    refute status.success?, output
    assert_includes output, "new-action/run.sh"

    commit_pin_to_head
    FileUtils.rm_rf(File.join(@repo, "new-action"))
    commit("remove the action")
    output, status = check
    refute status.success?, output
    assert_includes output, "new-action/action.yml"
  end

  def test_a_nested_action_counts_and_a_directory_without_one_does_not
    pin_workflow(@code)
    write("docs/guide/action.md", "not an action\n")
    write("docs/guide/notes.md", "notes\n")
    commit("docs")
    output, status = check
    assert status.success?, output

    write("tools/lint/action.yaml", "name: nested\n")
    commit("nested action")
    output, status = check
    refute status.success?, output
    assert_includes output, "tools/lint/action.yaml"
  end

  # A root action's directory is the whole repository, pins included, so its action file counts.
  def test_a_root_action_counts
    pin_workflow(@code)
    write("action.yml", "name: root\n")
    commit("root action")
    output, status = check
    refute status.success?, output
    assert_includes output, "action.yml"

    commit_pin_to_head
    write("docs/notes.md", "docs only\n")
    commit("docs")
    output, status = check
    assert status.success?, output
  end

  def commit_pin_to_head =pin_workflow(git("rev-parse", "HEAD").strip)

  def test_several_pins_a_short_pin_or_an_unknown_commit_fail
    [[@code, "f" * 40], [@code[0, 7]], ["e" * 40]].each do |shas|
      pin_workflow(*shas)
      _output, status = check
      refute status.success?, shas.inspect
    end
  end

  def test_a_mixed_case_reference_is_read_too
    write(".github/workflows/remote-consumer.yml", "      - uses: MarcOrtola/CI-Deploy/deploy@#{'f' * 40}\n      - uses: marcortola/ci-deploy/setup@#{@code}\n")
    commit("pins")
    output, status = check
    refute status.success?
    assert_includes output, "several revisions"
  end
end
