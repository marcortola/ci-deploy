# frozen_string_literal: true

require_relative "../test_helper"
require "ci_deploy/hosts"

class HostsTest < Minitest::Test
  def list(value, **options) = CiDeploy::Hosts.list("WEB_SERVER_IPS", env: { "WEB_SERVER_IPS" => value }, **options)

  def test_one_host
    assert_equal ["192.0.2.10"], list("192.0.2.10")
  end

  def test_several_hosts_comma_separated
    assert_equal ["192.0.2.10", "192.0.2.11"], list("192.0.2.10,192.0.2.11")
  end

  def test_several_hosts_space_or_newline_separated_as_older_consumers_wrote_them
    assert_equal ["192.0.2.10", "192.0.2.11", "192.0.2.12"], list("192.0.2.10 192.0.2.11\n192.0.2.12")
  end

  def test_mixed_separators_surrounding_whitespace_and_duplicates
    assert_equal ["192.0.2.10", "192.0.2.11"], list("  192.0.2.10, 192.0.2.11,,192.0.2.10 \n")
  end

  def test_first_reads_one_host_from_a_list
    assert_equal "192.0.2.10", CiDeploy::Hosts.first("DB", env: { "DB" => "192.0.2.10,192.0.2.11" })
  end

  def test_first_raises_by_default_when_the_variable_holds_no_host
    error = assert_raises(CiDeploy::Hosts::MissingHosts) { CiDeploy::Hosts.first("DB", env: {}) }
    assert_includes error.message, "DB"
    assert_raises(CiDeploy::Hosts::MissingHosts) { CiDeploy::Hosts.first("DB", env: { "DB" => " , " }) }
  end

  def test_optional_first_is_nil_without_a_host_and_the_first_host_otherwise
    assert_nil CiDeploy::Hosts.first("DB", required: false, env: {})
    assert_nil CiDeploy::Hosts.first("DB", required: false, env: { "DB" => "" })
    assert_equal "192.0.2.30", CiDeploy::Hosts.first("DB", required: false, env: { "DB" => "192.0.2.30 192.0.2.31" })
  end

  def test_missing_variable_raises_naming_it
    error = assert_raises(CiDeploy::Hosts::MissingHosts) { CiDeploy::Hosts.list("WORKER_SERVER_IPS", env: {}) }
    assert_includes error.message, "WORKER_SERVER_IPS"
  end

  def test_empty_value_raises
    assert_raises(CiDeploy::Hosts::MissingHosts) { list(" , ") }
  end

  def test_optional_list_may_be_empty
    assert_equal [], list("", required: false)
  end
end
