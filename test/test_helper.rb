# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.join(ROOT, "lib")

require "ci_deploy/cli"

module TestSupport
  FIXTURES = File.join(ROOT, "test", "fixtures")

  # A Runner double: records every argument vector and answers from rules. A rule matches when its
  # pattern is a prefix of the call's argv (an Array) or matches the joined argv (a Regexp). A rule
  # with several responses answers them in turn and repeats the last.
  class FakeRunner
    Rule = Struct.new(:pattern, :responses, :used)

    attr_reader :calls, :envs

    def initialize
      @calls = []
      @envs = []
      @rules = []
    end

    def on(pattern, *responses)
      responses = [{}] if responses.empty?
      @rules << Rule.new(pattern, responses, 0)
      self
    end

    def run(*argv, echo: true, quiet: false, env: {})
      argv = argv.flatten.map(&:to_s)
      @calls << argv
      @envs << env
      rule = @rules.reverse.find { |candidate| matches?(candidate.pattern, argv) }
      response = if rule
                   chosen = rule.responses[[rule.used, rule.responses.size - 1].min]
                   rule.used += 1
                   chosen
                 else
                   {}
                 end
      CiDeploy::Runner::Result.new(status: response.fetch(:status, 0), output: response.fetch(:output, ""))
    end

    # Calls whose argv starts with the given words (kamal calls are matched without "kamal").
    def kamal_calls
      @calls.select { |argv| argv.first == "kamal" }.map { |argv| argv.drop(1) }
    end

    private

    def matches?(pattern, argv)
      case pattern
      when Array then argv.first(pattern.size) == pattern
      when Regexp then argv.join(" ").match?(pattern)
      end
    end
  end

  # A Github writer backed by real GITHUB_ENV/GITHUB_OUTPUT files, so tests read back exactly what
  # later steps would see.
  class GithubFiles
    attr_reader :env, :out, :dir

    def initialize
      @dir = Dir.mktmpdir("ci-deploy-gh")
      @env = {}
      %w[GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH].each do |name|
        path = File.join(@dir, name.downcase)
        File.write(path, "")
        @env[name] = path
      end
      @out = StringIO.new
    end

    def github = CiDeploy::Github.new(env: @env, out: @out)
    def outputs = TestSupport.parse_github_file(@env["GITHUB_OUTPUT"])
    def exported = TestSupport.parse_github_file(@env["GITHUB_ENV"])
    def log = @out.string

    def cleanup
      FileUtils.rm_rf(@dir)
    end
  end

  # Parses the NAME<<DELIMITER form (and plain NAME=value lines) the way the runner does; later
  # entries win.
  def self.parse_github_file(path)
    values = {}
    lines = File.read(path).lines(chomp: true)
    until lines.empty?
      line = lines.shift
      if (match = line.match(/\A([^=<]+)<<(.+)\z/))
        body = []
        body << lines.shift until lines.first == match[2]
        lines.shift
        values[match[1]] = body.join("\n")
      elsif (match = line.match(/\A([^=]+)=(.*)\z/))
        values[match[1]] = match[2]
      end
    end
    values
  end

  # Executable stubs that record each call (program name and arguments, separated by \x1f, one
  # record per call, separated by \x1e) and then run a per-stub body.
  class Stubs
    attr_reader :bin, :log

    def initialize(dir)
      @bin = File.join(dir, "stub-bin")
      @log = File.join(dir, "stub-calls")
      FileUtils.mkdir_p(@bin)
      File.write(@log, "")
    end

    def add(name, body = "exit 0")
      path = File.join(@bin, name)
      File.write(path, <<~SH)
        #!/bin/sh
        { printf '%s' "#{name}"; for a in "$@"; do printf '\\037%s' "$a"; done; printf '\\036'; } >> "#{@log}"
        #{body}
      SH
      File.chmod(0o755, path)
      path
    end

    def calls
      File.read(@log).split("\x1e").map { |record| record.split("\x1f", -1) }
    end

    def calls_to(name)
      calls.select { |call| call.first == name }.map { |call| call.drop(1) }
    end

    def path(rest = ENV.fetch("PATH"))
      "#{@bin}:#{rest}"
    end
  end
end

class Minitest::Test
  # Child processes get the environment from before `bundle exec`: bundler/setup would otherwise put
  # the bundle's bin directory ahead of the stubs on PATH. CI runs bin/ci-deploy the same way.
  def clean_env(env)
    base = defined?(Bundler) ? Bundler.unbundled_env : ENV.to_h
    base.merge(env)
  end

  def spawn_options = { unsetenv_others: true }

  def tmpdir
    @tmpdir ||= Dir.mktmpdir("ci-deploy-test").tap { |dir| (@cleanup ||= []) << dir }
  end

  def after_teardown
    (@cleanup || []).each { |dir| FileUtils.rm_rf(dir) }
    super
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
