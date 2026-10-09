# frozen_string_literal: true

require_relative "../test_helper"

class NotifyTest < Minitest::Test
  def setup
    @gh = TestSupport::GithubFiles.new
    @requests = []
  end

  def teardown = @gh.cleanup

  def notify(env: {}, status: 200, raise_error: nil, **overrides)
    http = lambda do |uri, body, headers|
      raise raise_error if raise_error

      @requests << [uri.to_s, JSON.parse(body), headers]
      status
    end
    arguments = { explicit_token: "", environment: "staging", deploy_result: "success", rollback_result: "not-needed",
                  repository: "example/app", revision: "abc", actor: "octocat", run_url: "https://github.example/run/1" }.merge(overrides)
    result = nil
    capture_stdout { result = CiDeploy::Notify.new(github: @gh.github, env: env, http: http).call(**arguments) }
    result
  end

  def test_no_token_skips_reporting
    assert_equal :skipped, notify
    assert_empty @requests
  end

  def test_the_skip_notice_names_what_is_not_reported
    notify(deploy_result: "deploy-failed")
    assert_includes @gh.log, "::notice::No Rollbar token configured; the deploy outcome is not reported to Rollbar."
    notify(deploy_result: "setup-failed")
    assert_includes @gh.log, "::notice::No Rollbar token configured; the setup failure is not reported to Rollbar."
  end

  def test_success_records_a_deploy_and_raises_no_item
    notify(explicit_token: "token-1")
    assert_equal 1, @requests.size
    uri, body, headers = @requests.first
    assert_equal "https://api.rollbar.com/api/1/deploy", uri
    assert_equal "succeeded", body["status"]
    assert_equal "token-1", headers["X-Rollbar-Access-Token"]
  end

  def test_failure_records_a_failed_deploy_and_a_critical_item
    notify(explicit_token: "token-1", deploy_result: "deploy-failed", rollback_result: "failed")
    assert_equal ["https://api.rollbar.com/api/1/deploy", "https://api.rollbar.com/api/1/item/"], @requests.map(&:first)
    assert_equal "failed", @requests[0][1]["status"]
    item = @requests[1][1]["data"]
    assert_equal "critical", item["level"]
    assert_includes item["body"]["message"]["body"], "deploy-failed, rollback: failed"
  end

  def test_an_interrupted_deploy_reports_timed_out
    notify(explicit_token: "token-1", deploy_result: "")
    assert_equal "timed_out", @requests[0][1]["status"]
  end

  def test_token_falls_back_to_the_known_variable_names_in_order
    notify(env: { "ROLLBAR_ACCESS_TOKEN" => "third", "ROLLBAR_SERVER_TOKEN" => "second" })
    assert_equal "second", @requests.first[2]["X-Rollbar-Access-Token"]
  end

  def test_token_is_read_from_the_secrets_json_over_the_environment
    notify(secrets_json: JSON.generate("ROLLBAR_SERVER_TOKEN" => "from-secrets"), env: { "ROLLBAR_SERVER_TOKEN" => "from-env" })
    assert_equal "from-secrets", @requests.last[2]["X-Rollbar-Access-Token"]
    notify(secrets_json: JSON.generate("ROLLBAR_ACCESS_TOKEN" => "third", "ROLLBAR_TOKEN" => "first"))
    assert_equal "first", @requests.last[2]["X-Rollbar-Access-Token"]
    notify(explicit_token: "explicit", secrets_json: JSON.generate("ROLLBAR_TOKEN" => "from-secrets"))
    assert_equal "explicit", @requests.last[2]["X-Rollbar-Access-Token"]
  end

  def test_secrets_json_that_does_not_parse_or_holds_no_string_token_falls_back_to_the_environment
    ["not json", "[1]", JSON.generate("ROLLBAR_TOKEN" => ""), JSON.generate("ROLLBAR_TOKEN" => { "nested" => "x" }), JSON.generate("OTHER" => "x")].each do |json|
      @requests.clear
      notify(secrets_json: json, env: { "ROLLBAR_TOKEN" => "from-env" })
      assert_equal "from-env", @requests.last[2]["X-Rollbar-Access-Token"], json
    end
    @requests.clear
    assert_equal :skipped, notify(secrets_json: "not json")
    assert_empty @requests
  end

  def test_a_setup_failure_is_a_failed_deploy_with_a_critical_item_saying_nothing_was_deployed
    notify(explicit_token: "t", deploy_result: "setup-failed", rollback_result: "not-attempted")
    assert_equal "failed", @requests[0][1]["status"]
    item = @requests[1][1]["data"]
    assert_equal "critical", item["level"]
    assert_equal "deploy-failed-example/app-staging", item["fingerprint"]
    message = item["body"]["message"]["body"]
    assert_includes message, "setup-failed, rollback: not-attempted"
    assert_includes message, "nothing was deployed"
    refute_includes message, "post-deploy step"
  end

  def test_endpoint_can_be_overridden
    notify(explicit_token: "t", env: { "CI_DEPLOY_ROLLBAR_ENDPOINT" => "http://127.0.0.1:9/" })
    assert_equal "http://127.0.0.1:9/api/1/deploy", @requests.first[0]
  end

  def test_errors_and_error_responses_are_swallowed_with_a_warning
    assert_equal :reported, notify(explicit_token: "t", status: 500)
    assert_includes @gh.log, "::warning::Rollbar answered HTTP 500"
    assert_equal :reported, notify(explicit_token: "t", deploy_result: "deploy-failed", raise_error: SocketError.new("down"))
    assert_includes @gh.log, "::warning::Could not report the deploy to Rollbar (SocketError)"
  end
end
