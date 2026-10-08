# frozen_string_literal: true

require "fileutils"
require "shellwords"
require_relative "github"
require_relative "runner"
require_relative "kamal"
require_relative "deploy"
require_relative "metadata"
require_relative "terraform_outputs"

module CiDeploy
  # The local half of the launcher: runs inside the bundle the wrapper prepared, in the consumer's
  # own directory, with the same helpers CI uses.
  #
  #   ci-deploy-local [launcher options] [--] <kamal arguments>
  #
  # Launcher options (all explicit; nothing is read from a default credentials location):
  #   --env-file FILE          KEY=VALUE credentials and settings; repeatable, later files win
  #   --config FILE            Kamal configuration (default etc/kamal/deploy.yml)
  #   --secrets-file FILE      copied to .kamal/ as in CI (default etc/kamal/secrets-common, if present)
  #   --outputs-map FILE       Terraform outputs map, as in the setup action
  #   --terraform-workspace ID workspace to read it from; the token comes from TF_API_TOKEN
  #   --rollback auto|off      rollback policy for `deploy` (default off)
  #   --branch-policy enforce|off  production-branch guard for `deploy` (default enforce)
  #
  # `deploy` runs the same build-then-deploy flow as the deploy action, with one explicit version;
  # `deploy --skip-push --version V` deploys a prebuilt image and refuses to start unless that
  # image is already published. Every other Kamal command is passed through unchanged.
  class Local
    class Usage < ArgumentError; end

    DEPLOY_FLAGS = %w[--skip-push -H --skip-hooks].freeze

    def initialize(argv, env: ENV, out: $stdout, exec: ->(env, argv) { Kernel.exec(env, *argv) })
      @argv = argv.dup
      @env = env
      @out = out
      @exec = exec
      @options = { env_files: [], config: "etc/kamal/deploy.yml", secrets_file: nil, outputs_map: nil, workspace: nil, rollback: "off", branch_policy: "enforce" }
    end

    def call
      kamal_args = parse_options
      raise Usage, "no Kamal command given" if kamal_args.empty?
      @env["CI_DEPLOY_CONFIG"] = @options[:config]

      @options[:env_files].each { |file| load_env_file(file) }
      prepare_secrets
      export_terraform_outputs

      if kamal_args.first == "deploy"
        managed_deploy(kamal_args.drop(1))
      else
        kamal_args += ["-c", @options[:config]] unless kamal_args.any? { |arg| arg.match?(/\A(-c|--config-file)(=.*)?\z/) }
        @exec.call({}, ["kamal", *kamal_args])
      end
    end

    def self.parse_env_file(text)
      text.each_line.with_index(1).each_with_object({}) do |(line, number), values|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        match = stripped.match(/\A(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/)
        raise Usage, "env file line #{number} is not KEY=VALUE" unless match

        raw = match[2]
        values[match[1]] = if raw.start_with?("'") && raw.end_with?("'") && raw.length >= 2
                             raw[1..-2]
                           elsif raw.start_with?('"') && raw.end_with?('"') && raw.length >= 2
                             raw[1..-2].gsub("\\n", "\n").gsub('\\"', '"').gsub("\\\\", "\\")
                           else
                             raw.sub(/\s+#.*\z/, "")
                           end
      end
    end

    private

    def parse_options
      args = @argv
      until args.empty?
        case args.first
        when "--" then return args.drop(1)
        when "--env-file" then @options[:env_files] << value(args, "--env-file")
        when "--config" then @options[:config] = value(args, "--config")
        when "--secrets-file" then @options[:secrets_file] = value(args, "--secrets-file")
        when "--outputs-map" then @options[:outputs_map] = value(args, "--outputs-map")
        when "--terraform-workspace" then @options[:workspace] = value(args, "--terraform-workspace")
        when "--rollback" then @options[:rollback] = value(args, "--rollback")
        when "--branch-policy" then @options[:branch_policy] = value(args, "--branch-policy")
        else return args
        end
      end
      args
    end

    def value(args, flag)
      args.shift
      raise Usage, "#{flag} needs a value" if args.empty? || args.first.start_with?("--")

      args.shift
    end

    def load_env_file(file)
      raise Usage, "env file #{file} does not exist" unless File.file?(file)

      self.class.parse_env_file(File.read(file)).each { |name, val| @env[name] = val }
    end

    def prepare_secrets
      file = @options[:secrets_file] || ("etc/kamal/secrets-common" if File.file?("etc/kamal/secrets-common"))
      return unless file
      raise Usage, "secrets file #{file} does not exist" unless File.file?(file)

      FileUtils.mkdir_p(".kamal")
      FileUtils.cp(file, File.join(".kamal", File.basename(file)))
    end

    def export_terraform_outputs
      return unless @options[:outputs_map]
      raise Usage, "outputs map #{@options[:outputs_map]} does not exist" unless File.file?(@options[:outputs_map])
      raise Usage, "--outputs-map needs --terraform-workspace" if @options[:workspace].to_s.empty?

      entries = TerraformOutputs.parse_map(File.read(@options[:outputs_map]))
      token = @env.fetch("TF_API_TOKEN", "")
      values, = TerraformOutputs.new(token: token, workspace: @options[:workspace], address: @env["CI_DEPLOY_TERRAFORM_ADDRESS"]).resolve(entries)
      values.each { |name, val| @env[name] = val }
      @out.puts "Resolved Terraform outputs: #{values.keys.join(', ')}"
    end

    def managed_deploy(args)
      destination = nil
      version = nil
      prebuilt = false
      skip_hooks = false
      config = @options[:config]
      until args.empty?
        arg = args.shift
        case arg
        when "-d", "--destination" then destination = args.shift
        when /\A--destination=(.+)\z/ then destination = Regexp.last_match(1)
        when "--version" then version = args.shift
        when /\A--version=(.+)\z/ then version = Regexp.last_match(1)
        when "-c", "--config-file" then config = args.shift
        when /\A--config-file=(.+)\z/ then config = Regexp.last_match(1)
        when "--skip-push" then prebuilt = true
        when "-H", "--skip-hooks" then skip_hooks = true
        else
          raise Usage, "deploy through the launcher accepts -d, -c, --version, --skip-push and --skip-hooks; #{arg} is not supported"
        end
      end
      raise Usage, "a prebuilt deploy (--skip-push) needs --version naming the published image" if prebuilt && version.to_s.empty?

      github = Github.new(env: @env, out: @out)
      runner = Runner.new(out: @out)
      kamal = Kamal.new(runner: runner, config: config, destination: destination)
      head = runner.run("git", "rev-parse", "HEAD", echo: false, quiet: true)
      branch = runner.run("git", "rev-parse", "--abbrev-ref", "HEAD", echo: false, quiet: true)
      Metadata.new(github: github, branch: branch.output.strip, commit: head.output.strip, destination: destination.to_s, policy: @options[:branch_policy]).tap(&:validate!).export

      outcome = Deploy.new(kamal: kamal, runner: runner, github: github, mode: prebuilt ? "prebuilt" : "kamal",
                           version: version, rollback: @options[:rollback], skip_hooks: skip_hooks).call
      @out.puts "Deploy result: #{outcome.deploy_result} (version #{outcome.version})"
      outcome.success? ? 0 : 1
    end
  end
end
