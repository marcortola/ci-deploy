# frozen_string_literal: true

require "securerandom"
require_relative "kamal"

module CiDeploy
  # Builds (or checks) one image version, deploys exactly that version and, when the policy allows
  # it, rolls a failed deploy back to the version that was serving before.
  #
  # Order matters and is the point of this class:
  #
  # 1. The version is fixed once. Kamal derives a version from the commit and, on a dirty tree,
  #    appends `_uncommitted_` and random hex that every kamal process draws afresh, so letting the
  #    build and the deploy each derive it would make them name different images.
  # 2. The version serving now is read before anything changes. It is only a read.
  # 3. The image is built and pushed (`kamal build push`), or, for a prebuilt image, confirmed to
  #    exist in the registry. Neither opens a connection to the hosts, so a failure here leaves the
  #    hosts untouched, and no rollback target is published: rolling back would reboot the healthy
  #    live container under this commit's environment for nothing.
  # 4. Only then does anything touch the hosts: the optional before-deploy command (for example
  #    pausing a service that competes with the rollout; it runs even with --skip-hooks, and its
  #    failure stops the deploy), then `kamal deploy --skip-push`.
  # 5. A failed deploy is rolled back only when the policy is `auto`. Repositories whose hooks run
  #    schema migrations keep it `off`: code that predates an applied migration can leave things
  #    worse than the failed deploy did.
  class Deploy
    MODES = %w[kamal prebuilt].freeze
    ROLLBACK_POLICIES = %w[auto off].freeze
    VERSION_FORMAT = /\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z/

    Outcome = Struct.new(:version, :previous_version, :deploy_result, :rollback_result, :image, keyword_init: true) do
      def success? = deploy_result == "success"
    end

    def initialize(kamal:, runner:, github:, mode: "kamal", version: nil, rollback: "off", skip_hooks: false, before_deploy: nil, image_check: nil, git: nil)
      raise ArgumentError, "build mode must be one of #{MODES.join(', ')}, not #{mode.inspect}" unless MODES.include?(mode)
      raise ArgumentError, "rollback policy must be one of #{ROLLBACK_POLICIES.join(', ')}, not #{rollback.inspect}" unless ROLLBACK_POLICIES.include?(rollback)

      @kamal = kamal
      @runner = runner
      @github = github
      @mode = mode
      @explicit_version = version.to_s
      @rollback = rollback
      @skip_hooks = skip_hooks
      @before_deploy = Array(before_deploy)
      @image_check = image_check || ImageCheck.new(kamal: kamal, runner: runner)
      @git = git || runner
    end

    def call
      version = resolve_version
      @github.set_output("version", version)
      puts "Deploying version: #{version}"

      serving = read_serving_version
      puts "Currently serving: #{serving.empty? ? 'unknown' : serving}"
      previous = rollback_target(serving, version)

      outcome = Outcome.new(version: version, previous_version: "", deploy_result: nil, rollback_result: "not-attempted")

      case @mode
      when "kamal"
        build = @kamal.run("build", "push", "--version=#{version}")
        return finish(outcome, "build-failed", "The build failed, so no host was touched and nothing is rolled back.") unless build.success?
      when "prebuilt"
        image = @image_check.call(version)
        outcome.image = image.reference
        return finish(outcome, "image-missing", image.message) unless image.published
      end

      # Published only now that the image exists: see step 3 above.
      outcome.previous_version = previous
      @github.set_output("previous-version", previous)

      unless @before_deploy.empty?
        before = @runner.run(*@before_deploy)
        unless before.success?
          return finish(outcome, "before-deploy-failed", "The before-deploy command exited with status #{before.status}, so kamal deploy did not run.")
        end
      end

      deploy_args = ["deploy", "--skip-push", "--version=#{version}"]
      deploy_args << "--skip-hooks" if @skip_hooks
      @github.warning("Deploying with --skip-hooks: the pre-deploy and post-deploy hooks will not run.") if @skip_hooks
      deploy = @kamal.run(*deploy_args)
      if deploy.success?
        outcome.rollback_result = "not-needed"
        return finish(outcome, "success", nil)
      end

      outcome.rollback_result = roll_back(previous)
      finish(outcome, "deploy-failed", "kamal deploy exited with status #{deploy.status}.")
    end

    private

    def finish(outcome, result, message)
      outcome.deploy_result = result
      @github.error(message) if message
      @github.set_output("deploy-result", result)
      @github.set_output("rollback-result", outcome.rollback_result)
      @github.set_output("previous-version", outcome.previous_version)
      @github.set_output("image", outcome.image.to_s)
      outcome
    end

    def resolve_version
      unless @explicit_version.empty?
        raise ArgumentError, "version #{@explicit_version.inspect} is not a valid image tag" unless @explicit_version.match?(VERSION_FORMAT)

        return @explicit_version
      end

      head = @git.run("git", "rev-parse", "HEAD", echo: false, quiet: true)
      raise ArgumentError, "the project directory is not a git checkout, so no version can be derived; pass one explicitly" unless head.success?

      version = head.output.strip
      status = @git.run("git", "status", "--porcelain", echo: false, quiet: true)
      if status.success? && !status.output.strip.empty?
        version = "#{version}_uncommitted_#{SecureRandom.hex(8)}"
        @github.warning("The working tree has uncommitted changes, so the version carries an _uncommitted_ suffix.")
      end
      version
    end

    def read_serving_version
      versions = @kamal.app_versions
      return "" if versions.nil?

      versions.values.find { |version| !version.empty? }.to_s
    end

    # Two versions are never a rollback target: the one being deployed (a redeploy of the same
    # version would roll back to the very image that just failed), and a `_replaced_` one, the name
    # Kamal gives a running container it renamed to boot the same version again.
    def rollback_target(serving, version)
      return "" if serving.empty? || serving == version || serving.include?("_replaced_")

      serving
    end

    def roll_back(previous)
      return "disabled" if @rollback == "off"
      return "no-target" if previous.empty?

      Rollback.new(kamal: @kamal, github: @github).call(previous) ? "succeeded" : "failed"
    end
  end

  # Confirms a prebuilt image is in the registry before any host is touched.
  class ImageCheck
    Result = Struct.new(:published, :reference, :message, keyword_init: true)

    def initialize(kamal:, runner:)
      @kamal = kamal
      @runner = runner
    end

    def call(version)
      reference = @kamal.absolute_image(version)
      login = @kamal.run("registry", "login", "--skip-remote")
      unless login.success?
        return Result.new(published: false, reference: reference, message: "Could not log in to the registry locally, so #{reference} could not be confirmed. No host was touched.")
      end

      inspect = ["docker", "manifest", "inspect"]
      inspect << "--insecure" if loopback?(reference)
      found = @runner.run(*inspect, reference, quiet: true)
      if found.success?
        Result.new(published: true, reference: reference, message: nil)
      else
        Result.new(published: false, reference: reference, message: "The image #{reference} is not published in the registry. Build and push it first; no host was touched.")
      end
    end

    private

    def loopback?(reference)
      reference.match?(%r{\A(localhost|127\.\d+\.\d+\.\d+)(:\d+)?/})
    end
  end

  # Rolls back to a previous version and confirms it is in effect. A rollback counts as done only
  # when both hold, because neither proves it alone:
  #
  # 1. `kamal rollback` exits 0. A failure inside Kamal (a missing environment value, a stale lock)
  #    must not read as success.
  # 2. Every app host reports the previous version. `kamal rollback` needs the previous container on
  #    the host, not merely the image, and exits 0 when that container is gone - so a rollback can
  #    "succeed" having done nothing. A version query that fails or returns no host counts as not
  #    rolled back.
  class Rollback
    def initialize(kamal:, github:)
      @kamal = kamal
      @github = github
    end

    def call(previous)
      puts "Deploy failed; rolling back to #{previous}."
      result = @kamal.run("rollback", previous)
      if result.output.include?("is not available as a container")
        @github.error("Rollback target #{previous} is no longer on the host, so nothing was rolled back. The failed version may still be serving - intervene manually.")
        return false
      end
      unless result.success?
        @github.error("kamal rollback exited with status #{result.status}, so the rollback to #{previous} did not complete. The failed version may still be serving - intervene manually.")
        return false
      end

      versions = @kamal.app_versions
      if versions.nil?
        @github.error("Could not read the running version from the hosts, so the rollback to #{previous} is unconfirmed. The failed version may still be serving - intervene manually.")
        return false
      end

      mismatches = versions.reject { |_host, version| version == previous }
      if versions.empty? || mismatches.any?
        @github.error("The rollback to #{previous} is not in effect on every host. The failed version may still be serving - intervene manually.")
        puts "  no host reported a version" if versions.empty?
        mismatches.each { |host, version| puts "  #{host}: #{version.empty? ? 'nothing running' : version}" }
        return false
      end

      @github.notice("Rolled back to #{previous}.")
      true
    end
  end
end
