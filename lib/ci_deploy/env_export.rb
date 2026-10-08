# frozen_string_literal: true

require "json"

module CiDeploy
  # Exports a workflow's variables and secrets (toJSON(vars), toJSON(secrets)) to the job, the way
  # Kamal's secrets files and ERB read them: as environment variables under their own names.
  #
  # Values go through the delimiter form of GITHUB_ENV, so multiline secrets such as private keys
  # survive intact. Secrets are masked line by line. Names that would change how the runner, Ruby,
  # SSH, Docker, Git, Node or this repository's own tooling behave are refused rather than
  # exported, whatever their case: toJSON(secrets) carries `github_token` in lower case.
  class EnvExport
    PROTECTED = /\A(PATH|HOME|SHELL|IFS|ENV|BASH_ENV|LD_[A-Z_]+|RUBY[A-Z_]*|GEM_[A-Z_]+|BUNDLE_[A-Z_]+|CI_DEPLOY_[A-Z0-9_]*|GITHUB_[A-Z0-9_]*|RUNNER_[A-Z0-9_]*|ACTIONS_[A-Z0-9_]*|SSH_AUTH_SOCK|NODE_OPTIONS|DOCKER_HOST|DOCKER_CONFIG|GIT_[A-Z0-9_]*)\z/i
    # Present in every toJSON(secrets), so it is skipped without a warning.
    AUTOMATIC = /\Agithub_token\z/i
    VALID_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    Result = Struct.new(:exported, :skipped, keyword_init: true)

    def initialize(github:)
      @github = github
    end

    def call(vars_json:, secrets_json:)
      exported = []
      skipped = []
      { vars: vars_json, secrets: secrets_json }.each do |kind, json|
        parse(json, kind).each do |name, value|
          if !name.match?(VALID_NAME) || name.match?(PROTECTED)
            skipped << name
            next if kind == :secrets && name.match?(AUTOMATIC)

            @github.warning("Not exporting #{kind == :secrets ? 'secret' : 'variable'} #{name}: the name is reserved or invalid.")
            next
          end

          string = value.is_a?(String) ? value : JSON.generate(value)
          @github.mask(string) if kind == :secrets
          @github.set_env(name, string)
          exported << name
        end
      end
      Result.new(exported: exported.uniq, skipped: skipped)
    end

    private

    def parse(json, kind)
      return {} if json.nil? || json.strip.empty?

      data = JSON.parse(json)
      raise ArgumentError, "#{kind} must be a JSON object, as toJSON(#{kind}) produces" unless data.is_a?(Hash)

      data.reject { |_name, value| value.nil? }
    rescue JSON::ParserError
      raise ArgumentError, "#{kind} is not valid JSON"
    end
  end
end
