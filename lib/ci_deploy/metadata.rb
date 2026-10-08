# frozen_string_literal: true

require "time"

module CiDeploy
  # Deploy metadata the configurations read (GIT_BRANCH, GIT_COMMIT, GIT_COMMIT_SHORT,
  # DEPLOY_TIMESTAMP, DEPLOY_ENV), and the guard that keeps the production branch and the
  # production destination paired: production deploys only from the production branch, and the
  # production branch deploys only to production.
  class Metadata
    POLICIES = %w[enforce off].freeze

    class PolicyViolation < StandardError; end

    def initialize(github:, branch:, commit:, destination:, production_branch: "main", production_destination: "production", policy: "enforce", clock: -> { Time.now.utc })
      raise ArgumentError, "branch policy must be one of #{POLICIES.join(', ')}, not #{policy.inspect}" unless POLICIES.include?(policy)

      @github = github
      @branch = branch.to_s
      @commit = commit.to_s
      @destination = destination.to_s
      @production_branch = production_branch.to_s
      @production_destination = production_destination.to_s
      @policy = policy
      @clock = clock
    end

    # A configuration without destinations (one file per environment, no -d) deploys to production
    # as far as this guard is concerned; the guard cannot tell its environment otherwise.
    def validate!
      return if @policy == "off"

      production = @destination.empty? || @destination == @production_destination
      if production && @branch != @production_branch
        raise PolicyViolation, "Production deployments are only allowed from the '#{@production_branch}' branch, not '#{@branch}'."
      end
      if !production && @branch == @production_branch
        raise PolicyViolation, "The '#{@production_branch}' branch is reserved for production and cannot be deployed to '#{@destination}'."
      end
    end

    def export
      timestamp = @clock.call.strftime("%Y-%m-%dT%H:%M:%SZ")
      values = {
        "GIT_BRANCH" => @branch,
        "GIT_COMMIT" => @commit,
        "GIT_COMMIT_SHORT" => @commit[0, 7],
        "DEPLOY_TIMESTAMP" => timestamp,
        "DEPLOY_ENV" => @destination.empty? ? @production_destination : @destination
      }
      values.each { |name, value| @github.set_env(name, value) }
      puts "Deployment summary:"
      puts "  Branch: #{@branch}"
      puts "  Commit: #{values['GIT_COMMIT_SHORT']}"
      puts "  Destination: #{@destination.empty? ? '(none)' : @destination}"
      puts "  Timestamp: #{timestamp}"
      values
    end
  end
end
