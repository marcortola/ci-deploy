# frozen_string_literal: true

require_relative "../test_helper"

class KamalTest < Minitest::Test
  def kamal(destination: nil)
    CiDeploy::Kamal.new(runner: TestSupport::FakeRunner.new, config: "services/api/etc/kamal/deploy-production.yml", destination: destination)
  end

  def test_argv_carries_the_config_and_no_destination_when_none_is_given
    assert_equal ["kamal", "app", "version", "-c", "services/api/etc/kamal/deploy-production.yml"], kamal.argv("app", "version")
  end

  def test_argv_carries_the_destination_when_given
    assert_equal ["kamal", "deploy", "-c", "services/api/etc/kamal/deploy-production.yml", "-d", "staging"],
                 kamal(destination: "staging").argv("deploy")
  end

  def test_a_configuration_is_required
    assert_raises(ArgumentError) { CiDeploy::Kamal.new(runner: nil, config: "") }
  end

  def test_parse_app_versions_for_one_host
    assert_equal({ "192.0.2.10" => "abc123" }, CiDeploy::Kamal.parse_app_versions("App Host: 192.0.2.10\nabc123\n\n"))
  end

  def test_parse_app_versions_skips_log_lines_and_handles_interleaving
    output = <<~OUT
        INFO [1a2b3c4d] Running docker ps on 192.0.2.10
      App Host: 192.0.2.10
      App Host: 192.0.2.11
        INFO [1a2b3c4d] Finished in 0.2 seconds with exit status 0 (successful).
      v1
      v2

    OUT
    assert_equal({ "192.0.2.10" => "v1", "192.0.2.11" => "v2" }, CiDeploy::Kamal.parse_app_versions(output))
  end

  def test_parse_app_versions_reports_a_host_with_nothing_running_as_empty
    assert_equal({ "192.0.2.10" => "" }, CiDeploy::Kamal.parse_app_versions("App Host: 192.0.2.10\n"))
  end

  def test_absolute_image_reads_kamal_config_with_symbol_keys
    runner = TestSupport::FakeRunner.new.on(%w[kamal config], output: "  INFO noise\n---\n:roles:\n- web\n:absolute_image: registry.example.com/example/app:v9\n")
    image = CiDeploy::Kamal.new(runner: runner, config: "etc/kamal/deploy.yml").absolute_image("v9")
    assert_equal "registry.example.com/example/app:v9", image
    assert_equal ["kamal", "config", "--version", "v9", "-c", "etc/kamal/deploy.yml"], runner.calls.first
  end

  def test_absolute_image_raises_when_kamal_config_fails
    runner = TestSupport::FakeRunner.new.on(%w[kamal config], status: 1, output: "ERROR (KeyError)\n")
    assert_raises(CiDeploy::Kamal::Error) { CiDeploy::Kamal.new(runner: runner, config: "etc/kamal/deploy.yml").absolute_image("v9") }
  end
end
