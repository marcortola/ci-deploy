# frozen_string_literal: true

require_relative "../test_helper"

class TerraformOutputsTest < Minitest::Test
  WORKSPACE = "ws-AbC123"

  def state(outputs)
    included = outputs.map do |name, (value, sensitive)|
      { "type" => "state-version-outputs", "attributes" => { "name" => name, "value" => value, "sensitive" => sensitive || false } }
    end
    JSON.generate({ "data" => {}, "included" => included })
  end

  def resolver(*responses, attempts: 3)
    @requests = []
    @sleeps = []
    queue = responses.dup
    http = lambda do |uri, headers|
      @requests << [uri.to_s, headers]
      response = queue.size > 1 ? queue.shift : queue.first
      raise response if response.is_a?(Exception)

      response
    end
    CiDeploy::TerraformOutputs.new(token: "example-token", workspace: WORKSPACE, http: http, attempts: attempts,
                                   delay: 1, sleeper: ->(seconds) { @sleeps << seconds })
  end

  def map(text) = CiDeploy::TerraformOutputs.parse_map(text)

  def test_parse_map_accepts_plain_first_and_optional_entries_and_comments
    entries = map("# hosts\nWEB_SERVER_IPS=web_server_ips\nDB_IP = db_private_ips[0]  # first only\n\nWORKER_SERVER_IPS=worker_server_ips?\n")
    assert_equal [["WEB_SERVER_IPS", "web_server_ips", false, false], ["DB_IP", "db_private_ips", true, false],
                  ["WORKER_SERVER_IPS", "worker_server_ips", false, true]], entries.map(&:to_a)
  end

  def test_parse_map_rejects_malformed_lines_and_duplicates
    assert_raises(CiDeploy::TerraformOutputs::Error) { map("WEB_SERVER_IPS") }
    assert_raises(CiDeploy::TerraformOutputs::Error) { map("WEB=$(id)") }
    assert_raises(CiDeploy::TerraformOutputs::Error) { map("A=x\nA=y") }
  end

  def test_lists_are_joined_with_commas_whatever_their_length
    values, sensitive = resolver([200, state("web" => [["192.0.2.10"]], "workers" => [["192.0.2.20", "192.0.2.21"]])])
                        .resolve(map("WEB=web\nWORKERS=workers"))
    assert_equal({ "WEB" => "192.0.2.10", "WORKERS" => "192.0.2.20,192.0.2.21" }, values)
    assert_empty sensitive
  end

  def test_first_element_and_scalar_outputs
    values, = resolver([200, state("dbs" => [["192.0.2.30", "192.0.2.31"]], "port" => [5432])])
              .resolve(map("DB=dbs[0]\nPORT=port"))
    assert_equal({ "DB" => "192.0.2.30", "PORT" => "5432" }, values)
  end

  def test_requests_the_current_state_with_the_token
    resolver([200, state("web" => [["192.0.2.10"]])]).resolve(map("WEB=web"))
    uri, headers = @requests.first
    assert_equal "https://app.terraform.io/api/v2/workspaces/#{WORKSPACE}/current-state-version?include=outputs", uri
    assert_equal "Bearer example-token", headers["Authorization"]
  end

  def test_sensitive_outputs_are_reported
    _, sensitive = resolver([200, state("key" => ["value", true])]).resolve(map("KEY=key"))
    assert_equal ["KEY"], sensitive
  end

  def test_missing_output_is_an_error_naming_it
    error = assert_raises(CiDeploy::TerraformOutputs::Error) { resolver([200, state({})]).resolve(map("WEB=web_server_ips")) }
    assert_includes error.message, "web_server_ips"
    assert_includes error.message, "missing or empty"
  end

  def test_empty_list_output_is_an_error
    assert_raises(CiDeploy::TerraformOutputs::Error) { resolver([200, state("web" => [[]])]).resolve(map("WEB=web")) }
  end

  def test_optional_output_may_be_missing_or_empty
    values, = resolver([200, state("empty" => [[]])]).resolve(map("A=missing?\nB=empty?"))
    assert_equal({ "A" => "", "B" => "" }, values)
  end

  def test_elements_with_separators_or_nested_values_are_refused
    assert_raises(CiDeploy::TerraformOutputs::Error) { resolver([200, state("web" => [["192.0.2.10 192.0.2.11"]])]).resolve(map("WEB=web")) }
    assert_raises(CiDeploy::TerraformOutputs::Error) { resolver([200, state("web" => [[{ "ip" => "192.0.2.10" }]])]).resolve(map("WEB=web")) }
    assert_raises(CiDeploy::TerraformOutputs::Error) { resolver([200, state("web" => ["192.0.2.10"])]).resolve(map("WEB=web[0]")) }
  end

  def test_refused_token_is_an_error_without_retrying
    error = assert_raises(CiDeploy::TerraformOutputs::Error) { resolver([401, "{}"]).resolve(map("WEB=web")) }
    assert_includes error.message, "HTTP 401"
    assert_includes error.message, "token"
    assert_equal 1, @requests.size
  end

  def test_unknown_workspace_is_an_error_with_a_hint
    error = assert_raises(CiDeploy::TerraformOutputs::Error) { resolver([404, "{}"]).resolve(map("WEB=web")) }
    assert_includes error.message, "workspace id"
  end

  # HCP Terraform has answered 404 for existing workspaces during an outage, so a 404 is retried
  # like a server error and the final error names both causes.
  def test_not_found_is_retried_and_the_final_error_names_a_wrong_workspace_or_an_outage
    error = assert_raises(CiDeploy::TerraformOutputs::Error) { resolver([404, "{}"]).resolve(map("WEB=web")) }
    assert_includes error.message, "HTTP 404"
    assert_includes error.message, "workspace id"
    assert_includes error.message, "token"
    assert_includes error.message, "outage"
    assert_equal 3, @requests.size
    assert_equal [1, 2], @sleeps
  end

  def test_a_transient_not_found_recovers_on_a_later_attempt
    values, = resolver([404, "{}"], [200, state("web" => [["192.0.2.10"]])]).resolve(map("WEB=web"))
    assert_equal({ "WEB" => "192.0.2.10" }, values)
    assert_equal 2, @requests.size
    assert_equal [1], @sleeps
  end

  def test_server_errors_and_network_failures_are_retried
    values, = resolver([502, ""], Errno::ECONNRESET.new, [200, state("web" => [["192.0.2.10"]])]).resolve(map("WEB=web"))
    assert_equal({ "WEB" => "192.0.2.10" }, values)
    assert_equal 3, @requests.size
    assert_equal [1, 2], @sleeps
  end

  def test_persistent_server_errors_fail_after_the_last_attempt
    error = assert_raises(CiDeploy::TerraformOutputs::Error) { resolver([503, ""]).resolve(map("WEB=web")) }
    assert_includes error.message, "HTTP 503"
    assert_equal 3, @requests.size
  end

  def test_unreachable_terraform_is_an_error
    error = assert_raises(CiDeploy::TerraformOutputs::Error) { resolver(SocketError.new("getaddrinfo")).resolve(map("WEB=web")) }
    assert_includes error.message, "could not be reached"
  end

  def test_a_body_that_is_not_json_is_an_error
    assert_raises(CiDeploy::TerraformOutputs::Error) { resolver([200, "<html>"]).resolve(map("WEB=web")) }
  end

  def test_token_and_workspace_are_required_and_validated
    entries = map("WEB=web")
    assert_raises(CiDeploy::TerraformOutputs::Error) { CiDeploy::TerraformOutputs.new(token: "", workspace: WORKSPACE).resolve(entries) }
    assert_raises(CiDeploy::TerraformOutputs::Error) { CiDeploy::TerraformOutputs.new(token: "t", workspace: "").resolve(entries) }
    assert_raises(CiDeploy::TerraformOutputs::Error) { CiDeploy::TerraformOutputs.new(token: "t", workspace: "../x").resolve(entries) }
  end

  def test_an_empty_map_makes_no_request
    assert_equal [{}, []], resolver([500, ""]).resolve([])
    assert_empty @requests
  end
end
