# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module CiDeploy
  # Reports a deploy's outcome to Rollbar. Two calls, deliberately:
  #
  #   /api/1/deploy  records every outcome on Rollbar's deploy timeline, which is what lets Rollbar
  #                  say "this error first appeared after deploy X" - so successes are recorded too.
  #   /api/1/item    is what alerts: a deploy entry runs no notification rules, an item does. Raised
  #                  at `critical` on failure only.
  #
  # This must never be the reason a deploy goes red, nor hide why one did: a missing token, an
  # unreachable Rollbar or an error response is logged and swallowed.
  class Notify
    TOKEN_VARIABLES = %w[ROLLBAR_TOKEN ROLLBAR_SERVER_TOKEN ROLLBAR_ACCESS_TOKEN LOG_ROLLBAR_ACCESS_TOKEN].freeze
    DEFAULT_ENDPOINT = "https://api.rollbar.com"
    # What a failed result means for the hosts, in the critical item's body.
    CONSEQUENCES = {
      "setup-failed" => "The setup action failed before the deploy started, so nothing was deployed and the previous version is still serving."
    }.freeze
    DEFAULT_CONSEQUENCE = "The previous version may still be serving, or a post-deploy step may have failed after the new one went live."

    def initialize(github:, env: ENV, http: nil)
      @github = github
      @env = env
      @http = http || method(:post)
    end

    # The token is the explicit input when given, otherwise the first of the names consumers have
    # historically stored it under, exported to the environment by the setup action. A setup
    # failure can come before that export, so the setup action passes its secrets JSON too: read
    # over the environment, as the export would have written it.
    def token(explicit, secrets_json: "")
      return explicit.to_s unless explicit.to_s.empty?

      secrets = parse_secrets(secrets_json)
      TOKEN_VARIABLES.map { |name| secrets.fetch(name, @env[name]).to_s }.find { |value| !value.empty? }.to_s
    end

    def call(explicit_token:, environment:, deploy_result:, rollback_result:, repository:, revision:, actor:, run_url:, secrets_json: "")
      token = token(explicit_token, secrets_json: secrets_json)
      if token.empty?
        subject = deploy_result == "setup-failed" ? "the setup failure" : "the deploy outcome"
        @github.notice("No Rollbar token configured; #{subject} is not reported to Rollbar.")
        return :skipped
      end

      success = deploy_result == "success"
      status = if success then "succeeded"
               elsif deploy_result.to_s.empty? then "timed_out"
               else "failed"
               end
      puts "Reporting deploy as '#{status}' to Rollbar (#{environment})."

      deploy_payload = {
        environment: environment, revision: revision, local_username: actor,
        comment: "#{repository} @ #{revision} - #{run_url}", status: status
      }
      send_request("/api/1/deploy", deploy_payload, { "X-Rollbar-Access-Token" => token }, "deploy")
      return :reported if success

      body = "Deploy failed (#{deploy_result.to_s.empty? ? 'cancelled or interrupted' : deploy_result}, rollback: #{rollback_result.to_s.empty? ? 'unknown' : rollback_result}): " \
             "#{repository} to #{environment}. #{CONSEQUENCES.fetch(deploy_result.to_s, DEFAULT_CONSEQUENCE)} Run: #{run_url}"
      item_payload = {
        access_token: token,
        data: {
          environment: environment, level: "critical", platform: "linux", language: "bash",
          framework: "github-actions", title: "Deploy failed: #{repository} (#{environment})",
          fingerprint: "deploy-failed-#{repository}-#{environment}", code_version: revision,
          body: { message: { body: body, repository: repository, run_url: run_url, revision: revision } },
          notifier: { name: "ci-deploy" }
        }
      }
      send_request("/api/1/item/", item_payload, {}, "item")
      :reported
    end

    private

    # Only string values under the token names count; JSON that does not parse (possibly why setup
    # failed) reads as no secrets, never as an error.
    def parse_secrets(json)
      return {} if json.to_s.strip.empty?

      data = JSON.parse(json)
      return {} unless data.is_a?(Hash)

      data.slice(*TOKEN_VARIABLES).select { |_name, value| value.is_a?(String) && !value.empty? }
    rescue JSON::ParserError
      {}
    end

    def send_request(path, payload, headers, label)
      endpoint = @env.fetch("CI_DEPLOY_ROLLBAR_ENDPOINT", "").then { |value| value.empty? ? DEFAULT_ENDPOINT : value }
      status = @http.call(URI("#{endpoint.chomp('/')}#{path}"), JSON.generate(payload), headers)
      puts "#{label} endpoint: HTTP #{status}"
      @github.warning("Rollbar answered HTTP #{status} to the #{label} report.") unless status.between?(200, 299)
    rescue StandardError => e
      @github.warning("Could not report the #{label} to Rollbar (#{e.class}).")
    end

    def post(uri, body, headers)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 20) do |http|
        http.post(uri.request_uri, body, { "Content-Type" => "application/json" }.merge(headers)).code.to_i
      end
    end
  end
end
