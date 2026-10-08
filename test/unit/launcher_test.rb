# frozen_string_literal: true

require_relative "../test_helper"

# The vendored local launcher, against a throwaway ci-deploy repository whose bin/ci-deploy and
# bin/kamal report what they were run with.
class LauncherTest < Minitest::Test
  LAUNCHER = File.join(ROOT, "launcher", "ci-deploy-local")
  GIT_ENV = { "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com", "GIT_COMMITTER_NAME" => "Test",
              "GIT_COMMITTER_EMAIL" => "test@example.com", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1" }.freeze

  def setup
    @upstream = File.join(tmpdir, "upstream")
    @cache = File.join(tmpdir, "cache")
    @component = File.join(tmpdir, "component")
    FileUtils.mkdir_p([@upstream, File.join(@component, ".github/workflows"), File.join(@component, "services/api")])
    build_upstream
  end

  def git(*args, chdir: @upstream)
    output, status = Open3.capture2e(clean_env(GIT_ENV), "git", *args, chdir: chdir, **spawn_options)
    raise "git #{args.join(' ')} failed: #{output}" unless status.success?

    output.strip
  end

  def build_upstream
    write_file(File.join(@upstream, "Gemfile"), "")
    write_file(File.join(@upstream, "Gemfile.lock"), "GEM\n  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n\nBUNDLED WITH\n   #{Bundler::VERSION}\n")
    write_file(File.join(@upstream, "bin/ci-deploy"), <<~'RUBY', 0o755)
      #!/usr/bin/env ruby
      puts "ARGS=#{ARGV.join('|')}"
      puts "PWD=#{Dir.pwd}"
      %w[BUNDLE_GEMFILE CI_DEPLOY_HOME CI_DEPLOY_HOOKS_LIB RUBYLIB].each { |name| puts "#{name}=#{ENV[name]}" }
      puts "PATH0=#{ENV['PATH'].split(':').first}"
      puts "HOOK=" + `sh -c 'printf "%s|%s" "$(command -v kamal)" "$BUNDLE_GEMFILE"'`
    RUBY
    write_file(File.join(@upstream, "bin/kamal"), "#!/bin/sh\necho kamal\n", 0o755)
    git("init", "-q")
    git("add", "-A")
    git("commit", "-q", "-m", "fixture")
    @sha = git("rev-parse", "HEAD")
  end

  def write_file(path, content, mode = nil)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    File.chmod(mode, path) if mode
  end

  def pin(file, ref, action: "setup")
    write_file(File.join(@component, ".github/workflows", file),
               "jobs:\n  deploy:\n    steps:\n      - uses: marcortola/ci-deploy/#{action}@#{ref} # v1.0.0\n")
  end

  def launch(*args, chdir: @component, env: {})
    base = { "CI_DEPLOY_CACHE" => @cache, "CI_DEPLOY_REPOSITORY_URL" => @upstream, "HOME" => tmpdir }.merge(GIT_ENV)
    output, status = Open3.capture2e(clean_env(base.merge(env)), "sh", LAUNCHER, *args, chdir: chdir, **spawn_options)
    [output, status]
  end

  def values(output) = output.lines(chomp: true).filter_map { |line| line.split("=", 2) if line.include?("=") }.to_h

  def test_runs_the_pinned_revision_with_its_bundle_and_helpers_for_nested_hooks
    pin("deploy.yml", @sha)
    pin("ops.yml", @sha, action: "operations")

    output, status = launch("--env-file", ".env", "--", "app", "details", chdir: File.join(@component, "services/api"))

    assert status.success?, output
    cache = File.join(@cache, @sha)
    seen = values(output)
    assert_equal "local|--env-file|.env|--|app|details", seen["ARGS"]
    assert_equal File.realpath(File.join(@component, "services/api")), File.realpath(seen["PWD"])
    assert_equal "#{cache}/Gemfile", seen["BUNDLE_GEMFILE"]
    assert_equal cache, seen["CI_DEPLOY_HOME"]
    assert_equal "#{cache}/lib/sh", seen["CI_DEPLOY_HOOKS_LIB"]
    assert seen["RUBYLIB"].start_with?("#{cache}/lib")
    assert_equal "#{cache}/bin", seen["PATH0"]
    assert_equal "#{cache}/bin/kamal|#{cache}/Gemfile", seen["HOOK"], "a nested hook must reach the same kamal and bundle"
    assert File.file?(File.join(cache, ".git/ci-deploy-ready"))
    assert_equal "", git("status", "--porcelain", chdir: cache).lines.reject { |line| line.include?(".bundle") }.join
  end

  def test_a_prepared_revision_is_reused_without_fetching
    pin("deploy.yml", @sha)
    _output, status = launch("app", "details")
    assert status.success?

    output, status = launch("app", "details", env: { "CI_DEPLOY_REPOSITORY_URL" => File.join(tmpdir, "gone") })
    assert status.success?, output
    refute_includes output, "preparing"
  end

  def test_mismatched_shas_fail_before_fetching_anything
    pin("deploy.yml", @sha)
    pin("ops.yml", "2222222222222222222222222222222222222222", action: "operations")

    output, status = launch("app", "details")

    refute status.success?
    assert_includes output, "pin marcortola/ci-deploy to 2 different revisions"
    refute Dir.exist?(@cache)
  end

  def test_a_tag_or_short_sha_is_refused
    %w[v1.0.0 1111111].each do |ref|
      pin("deploy.yml", ref)
      output, status = launch("app", "details")
      refute status.success?, ref
      assert_includes output, "not a full commit SHA"
    end
  end

  def test_no_reference_is_refused
    write_file(File.join(@component, ".github/workflows/ci.yml"), "jobs: {}\n")
    output, status = launch("app", "details")
    refute status.success?
    assert_includes output, "references marcortola/ci-deploy"
  end

  def test_outside_a_component_is_refused
    output, status = launch("app", "details", chdir: tmpdir)
    refute status.success?
    assert_includes output, "no .github/workflows"
  end

  def test_a_failed_fetch_leaves_no_cache_and_no_lock
    pin("deploy.yml", "3333333333333333333333333333333333333333")

    output, status = launch("app", "details")

    refute status.success?
    assert_includes output, "nothing was cached"
    assert_equal [], Dir.children(@cache)
  end

  def test_a_failed_bundle_install_leaves_no_cache
    write_file(File.join(@upstream, "Gemfile"), "gem \"definitely-not-a-real-gem-ci-deploy\"\n")
    git("commit", "-q", "-am", "unlocked gem")
    sha = git("rev-parse", "HEAD")
    pin("deploy.yml", sha)

    output, status = launch("app", "details")

    refute status.success?
    assert_includes output, "nothing was cached"
    assert_equal [], Dir.children(@cache)
  end

  def test_an_interrupted_bootstrap_lock_is_reported
    pin("deploy.yml", @sha)
    FileUtils.mkdir_p(File.join(@cache, "#{@sha}.lock"))

    output, status = launch("app", "details")

    refute status.success?
    assert_includes output, "remove #{@cache}/#{@sha}.lock"
  end
end
