# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"

# Renders the synthetic consumer configuration with the locked Kamal, as the setup action and the
# hooks run it: this repository's bin first on PATH, its lib on RUBYLIB, the secrets file
# prepared, hosts in the forms Terraform outputs arrive in.
class ConfigRenderTest < Minitest::Test
  def setup
    @project = File.join(tmpdir, "project")
    FileUtils.cp_r(File.join(TestSupport::FIXTURES, "consumer"), @project)
    FileUtils.mkdir_p(File.join(@project, ".kamal"))
    FileUtils.cp(File.join(@project, "etc/kamal/secrets-common"), File.join(@project, ".kamal/secrets-common"))
  end

  def render(env, *args)
    base = { "PATH" => "#{File.join(ROOT, 'bin')}:#{ENV.fetch('PATH')}", "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"),
             "RUBYLIB" => File.join(ROOT, "lib"), "REGISTRY_PASSWORD" => "example-password",
             "WEB_SERVER_IPS" => "192.0.2.10", "DATABASE_SERVER_IPS" => "192.0.2.30" }
    output, status = Open3.capture2e(clean_env(base.merge(env)), "kamal", "config", "-c", "etc/kamal/deploy.yml", *(args.include?("--version") ? args : [*args, "--version", "release-1"]),
                                     chdir: @project, **spawn_options)
    [status.success? ? YAML.safe_load(output[output.index("---")..], permitted_classes: [Symbol]) : nil, output]
  end

  # Kamal lists the accessory host (DATABASE_SERVER_IPS) among the hosts too.
  def app_hosts(config)
    assert_includes config[:hosts], "192.0.2.30"
    config[:hosts] - ["192.0.2.30"]
  end

  def test_one_host
    config, output = render({})
    assert config, output
    assert_equal ["192.0.2.10"], app_hosts(config)
    assert_equal ["web"], config[:roles]
    assert_equal "registry.example.com/example/app:release-1", config[:absolute_image]
  end

  def test_several_hosts_in_every_separator_form_render_the_same
    ["192.0.2.10,192.0.2.11", "192.0.2.10 192.0.2.11", "192.0.2.10\n192.0.2.11\n", " 192.0.2.10 , 192.0.2.11,192.0.2.10"].each do |value|
      config, output = render("WEB_SERVER_IPS" => value)
      assert config, output
      assert_equal ["192.0.2.10", "192.0.2.11"], app_hosts(config), value.inspect
    end
  end

  def test_optional_role_appears_only_with_hosts
    config, output = render("WORKER_SERVER_IPS" => "192.0.2.20,192.0.2.21")
    assert config, output
    assert_equal %w[web worker], config[:roles]
    assert_equal ["192.0.2.10", "192.0.2.20", "192.0.2.21"], app_hosts(config)
  end

  def test_destination_file_overrides_hosts
    config, output = render({ "STAGING_SERVER_IPS" => "192.0.2.50" }, "-d", "staging")
    assert config, output
    assert_equal ["192.0.2.50"], app_hosts(config)
    assert_equal "192.0.2.50", config[:primary_host]
  end

  def test_missing_hosts_fail_the_render_naming_the_variable
    config, output = render("WEB_SERVER_IPS" => "")
    assert_nil config
    assert_includes output, "WEB_SERVER_IPS holds no host"
  end

  def test_the_version_is_explicit
    config, output = render({}, "--version", "release-7")
    assert config, output
    assert_equal "registry.example.com/example/app:release-7", config[:absolute_image]
    assert_equal "example-app-release-7", config[:service_with_version]
  end

  # The reconcile hook parses this very output; a format change in Kamal must fail here.
  def test_reconcile_parses_the_real_kamal_output
    stubs = TestSupport::Stubs.new(tmpdir)
    stubs.add("ssh", "cat > /dev/null")
    env = { "PATH" => "#{stubs.bin}:#{File.join(ROOT, 'bin')}:#{ENV.fetch('PATH')}", "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"),
            "RUBYLIB" => File.join(ROOT, "lib"), "REGISTRY_PASSWORD" => "example-password", "WEB_SERVER_IPS" => "192.0.2.10",
            "WORKER_SERVER_IPS" => "192.0.2.20", "DATABASE_SERVER_IPS" => "192.0.2.30", "SSH_USER" => "deploy",
            "KAMAL_VERSION" => "release-7", "CI_DEPLOY_CONFIG" => "etc/kamal/deploy.yml" }
    output, status = Open3.capture2e(clean_env(env), "ci-deploy-reconcile-removed-roles", "-c", "etc/kamal/deploy.yml", "--version", "release-7",
                                     chdir: @project, **spawn_options)
    assert status.success?, output
    # Kamal lists accessory hosts too; on those the remote side finds no container of this service.
    assert_equal ["deploy@192.0.2.10", "deploy@192.0.2.20", "deploy@192.0.2.30"], stubs.calls_to("ssh").map { |call| call[-2] }
    assert_equal "sh -s 'example-app' '' 'web worker '", stubs.calls_to("ssh").first.last
  end

  # As a post-deploy hook calls it: no arguments, in a git checkout whose HEAD is not the version
  # being deployed (an explicit or prebuilt version). Kamal must render KAMAL_VERSION, or the
  # service name does not end in it and the reconcile skips.
  def test_reconcile_without_arguments_renders_the_deployed_version_not_head
    git_env = { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@example.com", "GIT_COMMITTER_NAME" => "t",
                "GIT_COMMITTER_EMAIL" => "t@example.com", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1" }
    [%w[init -q], %w[add -A], %w[commit -q -m fixture]].each do |args|
      system(clean_env(git_env), "git", *args, chdir: @project, exception: true, **spawn_options)
    end
    stubs = TestSupport::Stubs.new(tmpdir)
    stubs.add("ssh", "cat > /dev/null")
    env = { "PATH" => "#{stubs.bin}:#{File.join(ROOT, 'bin')}:#{ENV.fetch('PATH')}", "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"),
            "RUBYLIB" => File.join(ROOT, "lib"), "REGISTRY_PASSWORD" => "example-password", "WEB_SERVER_IPS" => "192.0.2.10",
            "DATABASE_SERVER_IPS" => "192.0.2.30", "SSH_USER" => "deploy", "KAMAL_VERSION" => "prebuilt-9",
            "CI_DEPLOY_CONFIG" => "etc/kamal/deploy.yml" }
    output, status = Open3.capture2e(clean_env(env), "ci-deploy-reconcile-removed-roles", chdir: @project, **spawn_options)
    assert status.success?, output
    assert_includes output, "[reconcile] example-app/none: desired roles = web"
    assert_equal "sh -s 'example-app' '' 'web '", stubs.calls_to("ssh").first&.last
  end
end
