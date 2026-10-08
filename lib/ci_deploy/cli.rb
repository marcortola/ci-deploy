# frozen_string_literal: true

require "fileutils"
require "shellwords"
require_relative "github"
require_relative "runner"
require_relative "kamal"
require_relative "deploy"
require_relative "metadata"
require_relative "notify"
require_relative "env_export"
require_relative "terraform_outputs"
require_relative "operations"
require_relative "revision_check"

module CiDeploy
  # Entry point for the actions' steps. Every input arrives as an environment variable (never
  # interpolated into a script), and every command runs as an argument vector.
  class CLI
    def initialize(argv, env: ENV, out: $stdout)
      @argv = argv
      @env = env
      @out = out
      @github = Github.new(env: env, out: out)
    end

    def run
      command = @argv.first.to_s
      handler = {
        "export-env" => :export_env,
        "terraform-outputs" => :terraform_outputs,
        "prepare-secrets" => :prepare_secrets,
        "kamal-env" => :kamal_env,
        "deploy" => :deploy,
        "cleanup" => :cleanup,
        "notify" => :notify,
        "finish" => :finish,
        "operation" => :operation,
        "revision-check" => :revision_check
      }[command]
      unless handler
        @out.puts "usage: ci-deploy <#{%w[export-env terraform-outputs prepare-secrets kamal-env deploy cleanup notify finish operation revision-check].join('|')}>"
        return 2
      end

      send(handler) || 0
    rescue ArgumentError, TerraformOutputs::Error, Metadata::PolicyViolation, Kamal::Error => e
      @github.error(e.message)
      1
    end

    private

    def input(name, default = "")
      value = @env.fetch("CI_DEPLOY_IN_#{name}", "").to_s
      value.strip.empty? ? default : value
    end

    def project_dir
      dir = @env.fetch("CI_DEPLOY_PROJECT_DIR", "")
      raise ArgumentError, "CI_DEPLOY_PROJECT_DIR is not set: run the setup action first" if dir.empty?
      raise ArgumentError, "project directory #{dir} does not exist" unless Dir.exist?(dir)

      dir
    end

    # The deploy and operations actions must run the very code the setup action prepared: same
    # revision, same bundle, same helpers on PATH.
    def ensure_same_revision!
      home = @env.fetch("CI_DEPLOY_HOME", "")
      raise ArgumentError, "CI_DEPLOY_HOME is not set: run the setup action first" if home.empty?

      action_home = @env.fetch("CI_DEPLOY_ACTION_HOME", "")
      return if action_home.empty? || File.realpath(action_home) == File.realpath(home)

      raise ArgumentError, "the setup action ran from #{home}, this action from #{action_home}: pin every marcortola/ci-deploy action to the same SHA"
    end

    def kamal
      config = input("CONFIG", @env.fetch("CI_DEPLOY_CONFIG", "etc/kamal/deploy.yml"))
      raise ArgumentError, "Kamal configuration #{config} not found in #{project_dir}" unless File.file?(File.join(project_dir, config))

      Kamal.new(runner: runner, config: config, destination: input("DESTINATION"))
    end

    def runner = Runner.new(out: @out, chdir: project_dir)

    def export_env
      result = EnvExport.new(github: @github).call(vars_json: input("VARS"), secrets_json: input("SECRETS"))
      @out.puts "Exported #{result.exported.size} variables and secrets."
      0
    end

    def terraform_outputs
      entries = TerraformOutputs.parse_map(input("OUTPUTS_MAP"))
      return 0 if entries.empty?

      values, sensitive = TerraformOutputs.new(token: input("TERRAFORM_TOKEN"), workspace: input("TERRAFORM_WORKSPACE"),
                                               address: input("TERRAFORM_ADDRESS")).resolve(entries)
      @out.puts "Resolved Terraform outputs:"
      values.each do |name, value|
        @github.mask(value) if sensitive.include?(name)
        @github.set_env(name, value)
        @out.puts "  #{name}=#{sensitive.include?(name) ? '(sensitive)' : value}"
      end
      0
    end

    def prepare_secrets
      file = input("SECRETS_FILE")
      return 0 if file.empty?

      source = File.join(project_dir, file)
      raise ArgumentError, "secrets file #{file} not found in #{project_dir}" unless File.file?(source)

      FileUtils.mkdir_p(File.join(project_dir, ".kamal"))
      FileUtils.cp(source, File.join(project_dir, ".kamal", File.basename(file)))
      @out.puts "Copied #{file} to .kamal/#{File.basename(file)}"
      0
    end

    # Kamal reads these while rendering the configuration, so every later kamal call needs them -
    # the deploy, and also the rollback and version reads after it. They are exported to the job.
    def kamal_env
      { "REGISTRY" => "REGISTRY", "REGISTRY_USER" => "REGISTRY_USER", "REGISTRY_PASSWORD" => "REGISTRY_PASSWORD",
        "SSH_USER" => "SSH_USER", "SSH_PORT" => "SSH_PORT" }.each do |input_name, variable|
        value = input(input_name)
        next if value.empty?

        @github.mask(value) if variable == "REGISTRY_PASSWORD"
        @github.set_env(variable, value)
      end
      0
    end

    # Any failure before Deploy reports its own result (a refused policy, an invalid input, a
    # project that is not a git checkout, `kamal config` failing) still sets deploy-result, so the
    # report says what happened instead of "cancelled or interrupted".
    def deploy
      ensure_same_revision!
      policy = input("BRANCH_POLICY", "enforce")
      metadata = Metadata.new(github: @github, branch: @env.fetch("GITHUB_REF_NAME", ""), commit: @env.fetch("GITHUB_SHA", ""),
                              destination: input("DESTINATION"), production_branch: input("PRODUCTION_BRANCH", "main"),
                              production_destination: input("PRODUCTION_DESTINATION", "production"),
                              policy: policy)
      begin
        metadata.validate!
        ensure_checkout_is_the_workflow_commit! if policy == "enforce"
      rescue Metadata::PolicyViolation
        @github.set_output("deploy-result", "refused")
        @github.set_output("rollback-result", "not-attempted")
        raise
      end
      metadata.export

      rollback = input("ROLLBACK")
      raise ArgumentError, "the rollback input is required: auto or off" if rollback.empty?

      outcome = Deploy.new(kamal: kamal, runner: runner, github: @github, mode: input("BUILD_MODE", "kamal"),
                           version: input("VERSION"), rollback: rollback,
                           skip_hooks: input("SKIP_HOOKS", "false") == "true", before_deploy: before_deploy_command,
                           command_env: command_env).call
      @out.puts "Deploy result: #{outcome.deploy_result}; rollback: #{outcome.rollback_result}"
      outcome.success? ? 0 : 1
    rescue ArgumentError, Kamal::Error => e
      @github.set_output("deploy-result", "error")
      @github.set_output("rollback-result", "not-attempted")
      raise e
    end

    # The branch policy checks GITHUB_REF_NAME and GITHUB_SHA; the code deployed is the checkout's
    # HEAD. Under `enforce` they must be the same commit, or a policy-checked run could deploy
    # other code.
    def ensure_checkout_is_the_workflow_commit!
      expected = @env.fetch("GITHUB_SHA", "")
      return if expected.empty?

      head = runner.run("git", "rev-parse", "HEAD", echo: false, quiet: true)
      return unless head.success?
      return if head.output.strip == expected

      raise Metadata::PolicyViolation,
            "The checkout is at #{head.output.strip}, not the workflow's commit #{expected}; with branch-policy enforce the deployed code must be the commit the policy checked."
    end

    # The before-deploy and cleanup commands see the destination the way Kamal's hooks do, so a
    # helper such as ci-deploy-host-control acts only for the destination being deployed. Without
    # a destination the variable is removed, never inherited from the job.
    def command_env
      destination = input("DESTINATION")
      { "KAMAL_DESTINATION" => destination.empty? ? nil : destination }
    end

    # Split like the cleanup command: words, no shell. Empty runs nothing.
    def before_deploy_command
      command = input("BEFORE_DEPLOY_COMMAND")
      return nil if command.empty?

      Shellwords.split(command)
    rescue ArgumentError => e
      raise ArgumentError, "the before-deploy command cannot be split: #{e.message}"
    end

    # Runs after the deploy whatever its result. Its own failure is reported and swallowed, so it
    # never replaces the deploy's result.
    def cleanup
      command = input("CLEANUP_COMMAND")
      return 0 if command.empty?

      argv = Shellwords.split(command)
      result = runner.run(*argv, env: command_env)
      @github.warning("The cleanup command exited with status #{result.status}; the deploy result is unchanged.") unless result.success?
      0
    rescue ArgumentError => e
      @github.warning("The cleanup command could not be parsed (#{e.message}); the deploy result is unchanged.")
      0
    end

    def notify
      destination = input("DESTINATION")
      environment = input("ENVIRONMENT_NAME", destination.empty? ? "production" : destination)
      Notify.new(github: @github, env: @env).call(
        explicit_token: input("ROLLBAR_TOKEN"), environment: environment,
        deploy_result: input("RESULT"), rollback_result: input("ROLLBACK_RESULT"),
        repository: @env.fetch("GITHUB_REPOSITORY", ""), revision: @env.fetch("GITHUB_SHA", ""),
        actor: @env.fetch("GITHUB_ACTOR", ""),
        run_url: "#{@env.fetch('GITHUB_SERVER_URL', 'https://github.com')}/#{@env.fetch('GITHUB_REPOSITORY', '')}/actions/runs/#{@env.fetch('GITHUB_RUN_ID', '')}"
      )
      0
    rescue StandardError => e
      @github.warning("Deploy reporting failed (#{e.class}); the deploy result is unchanged.")
      0
    end

    # Restores the deploy's own result after the steps that always run.
    def finish
      result = input("RESULT")
      rollback = input("ROLLBACK_RESULT")
      if rollback == "failed"
        @github.error("The rollback did not complete. The failed version may still be serving - intervene manually.")
      end
      return 0 if result == "success"

      @github.error("Deploy finished with result '#{result.empty? ? 'unknown (the deploy step did not complete)' : result}'.")
      1
    end

    def operation
      ensure_same_revision!
      inputs = %w[operation target command args roles hosts server container-mode stack lines since grep].to_h do |name|
        [name, input(name.upcase.tr("-", "_"))]
      end
      argvs = Operations.new(inputs).argvs
      kamal_runner = kamal
      argvs.each do |args|
        result = kamal_runner.run(*args)
        return result.status unless result.success?
      end
      0
    rescue Operations::Invalid => e
      @github.error(e.message)
      1
    end

    def revision_check
      component = input("COMPONENT", ".")
      check = RevisionCheck.new(component: component, workflows: input("WORKFLOWS", ".github/workflows"),
                                own_ref: input("OWN_REF", RevisionCheck.ref_from_action_path(@env.fetch("CI_DEPLOY_ACTION_HOME", ""))))
      result = check.call
      result.errors.each { |error| @github.error(error) }
      return 1 unless result.ok?

      @out.puts "#{RevisionCheck::REPOSITORY} is pinned to #{result.sha} in #{result.references.size} references."
      @github.set_output("sha", result.sha)
      0
    end
  end
end
