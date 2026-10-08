# frozen_string_literal: true

require_relative "../test_helper"

# The shared CI scripts behind the container, dependabot-merge, terraform and setup actions, with
# recording stubs for docker, gh and terraform.
class ContainerBuildTest < Minitest::Test
  SCRIPT = File.join(ROOT, "lib/sh/container-build.sh")

  def setup
    @stubs = TestSupport::Stubs.new(tmpdir)
    @stubs.add("docker", <<~'SH')
      if [ "$1" = login ]; then cat > "$0.password"; fi
      if [ "$1" = run ] && [ -n "${SMOKE_FAIL:-}" ]; then exit 1; fi
      exit 0
    SH
  end

  def build(env)
    Open3.capture2e(clean_env({ "PATH" => @stubs.path }.merge(env)), "bash", SCRIPT, chdir: tmpdir, **spawn_options)
  end

  def test_builds_every_tag_then_smoke_tests_the_first_without_the_runner_shell_and_does_not_push_by_default
    marker = File.join(tmpdir, "pwned")
    output, status = build("IMAGE_TAGS" => "example/app:ci\nexample/app:latest\n", "BUILD_FILE" => "docker/Dockerfile",
                           "BUILD_TARGET" => "runtime", "BUILD_ARGS" => "APP_ENV=test\nNPM_TOKEN", "BUILD_CACHE" => "gha",
                           "SMOKE_COMMANDS" => "php -v\ntest -f /app/vendor/autoload.php; touch #{marker}",
                           "SMOKE_RUN_ARGS" => "--network none --env-file .env.example")
    assert status.success?, output
    calls = @stubs.calls_to("docker")
    assert_equal ["buildx", "build", "--load", "--progress", "plain", "--file", "docker/Dockerfile", "--target", "runtime",
                  "--tag", "example/app:ci", "--tag", "example/app:latest", "--build-arg", "APP_ENV=test", "--build-arg", "NPM_TOKEN",
                  "--cache-from", "type=gha", "--cache-to", "type=gha,mode=max", "."], calls[0]
    assert_equal ["run", "--rm", "--network", "none", "--env-file", ".env.example", "example/app:ci", "sh", "-c", "php -v"], calls[1]
    assert_equal "test -f /app/vendor/autoload.php; touch #{marker}", calls[2].last
    refute File.exist?(marker)
    assert_equal 3, calls.size
  end

  def test_a_failed_smoke_command_stops_before_publishing
    _output, status = build("IMAGE_TAGS" => "example/app:ci", "SMOKE_COMMANDS" => "true", "PUSH" => "true", "SMOKE_FAIL" => "1")
    refute status.success?
    refute(@stubs.calls_to("docker").any? { |call| call.first == "push" })
  end

  def test_publishes_every_tag_after_logging_in_with_the_password_on_stdin
    _output, status = build("IMAGE_TAGS" => "registry.example.com/app:1\nregistry.example.com/app:latest", "PUSH" => "true",
                            "BUILD_CACHE" => "none", "REGISTRY" => "registry.example.com", "REGISTRY_USER" => "ci",
                            "REGISTRY_PASSWORD" => "example-password")
    assert status.success?
    calls = @stubs.calls_to("docker")
    assert_equal ["login", "registry.example.com", "--username", "ci", "--password-stdin"], calls[1]
    assert_equal [%w[push registry.example.com/app:1], %w[push registry.example.com/app:latest]], calls.last(2)
    assert_equal "example-password", File.read(File.join(@stubs.bin, "docker.password"))
    refute(calls.flatten.include?("example-password"))
  end

  def test_tags_are_required_and_the_cache_is_validated
    _output, status = build("IMAGE_TAGS" => " \n")
    assert_equal 64, status.exitstatus
    _output, status = build("IMAGE_TAGS" => "a:b", "BUILD_CACHE" => "s3")
    assert_equal 64, status.exitstatus
    assert_empty @stubs.calls
  end
end

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

class TerraformCheckTest < Minitest::Test
  SCRIPT = File.join(ROOT, "lib/sh/terraform-check.sh")

  def setup
    @stubs = TestSupport::Stubs.new(tmpdir)
    @stubs.add("terraform", <<~'SH')
      for a in "$@"; do case "$a" in
        fmt) [ -z "${FMT_FAIL:-}" ] || exit 3 ;;
        init) n=$(cat "$0.init" 2>/dev/null || echo 0); echo $((n + 1)) > "$0.init"; [ "$n" -ge "${INIT_FAILS:-0}" ] || exit 1 ;;
        validate) case "$1" in *"${VALIDATE_FAIL:-none}") exit 1 ;; esac ;;
      esac; done
      exit 0
    SH
    @root = File.join(tmpdir, "terraform")
    %w[environments/production environments/staging modules/network].each { |dir| FileUtils.mkdir_p(File.join(@root, dir)) }
    File.write(File.join(@root, "environments/production/backend.tf"), "")
    File.write(File.join(@root, "environments/staging/backend.tf"), "")
    FileUtils.mkdir_p(File.join(@root, "environments/staging/.terraform/modules/x"))
    File.write(File.join(@root, "environments/staging/.terraform/modules/x/backend.tf"), "")
  end

  def check(env = {})
    base = { "PATH" => @stubs.path, "TF_ROOT" => @root, "TF_RETRY_DELAY" => "0" }
    Open3.capture2e(clean_env(base.merge(env)), "bash", SCRIPT, **spawn_options)
  end

  def test_discovers_root_modules_by_backend_and_passes_init_arguments
    output, status = check("TF_INIT_ARGS" => "-backend=false -input=false -lockfile=readonly")
    assert status.success?, output
    calls = @stubs.calls_to("terraform")
    assert_equal ["fmt", "-check", "-diff", "-recursive", @root], calls[0]
    assert_equal ["-chdir=#{@root}/environments/production", "init", "-backend=false", "-input=false", "-lockfile=readonly", "-no-color"], calls[1]
    assert_equal ["-chdir=#{@root}/environments/production", "validate", "-no-color"], calls[2]
    assert_equal "-chdir=#{@root}/environments/staging", calls[3][0]
    assert_equal 5, calls.size, "modules under .terraform are not root modules"
  end

  def test_init_is_retried_then_succeeds
    output, status = check("INIT_FAILS" => "2", "TF_DIRECTORIES" => "#{@root}/environments/production", "TF_FMT" => "false")
    assert status.success?, output
    assert_equal 3, @stubs.calls_to("terraform").count { |call| call[1] == "init" }
  end

  def test_every_module_is_checked_after_a_failure_and_the_run_fails
    output, status = check("VALIDATE_FAIL" => "environments/production", "FMT_FAIL" => "1")
    refute status.success?
    assert_includes output, "formatting under #{@root}"
    assert_includes output, "environments/production (validate)"
    assert(@stubs.calls_to("terraform").any? { |call| call[0] == "-chdir=#{@root}/environments/staging" && call[1] == "validate" })
  end

  def test_init_exhausting_its_attempts_fails_without_validating
    output, status = check("INIT_FAILS" => "9", "TF_INIT_ATTEMPTS" => "2", "TF_DIRECTORIES" => "#{@root}/environments/staging", "TF_FMT" => "false")
    refute status.success?
    assert_includes output, "after 2 attempts"
    refute(@stubs.calls_to("terraform").any? { |call| call[1] == "validate" })
  end

  def test_no_root_module_is_an_error
    _output, status = check("TF_ROOT" => File.join(@root, "modules"))
    refute status.success?
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
