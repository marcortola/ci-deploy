# frozen_string_literal: true

require "open3"
require "shellwords"

module CiDeploy
  # Runs commands as argument vectors, never through a shell, so no value from a workflow input,
  # a secret or a Terraform output is ever parsed by the runner's shell.
  class Runner
    Result = Struct.new(:status, :output, keyword_init: true) do
      def success? = status.zero?
    end

    def initialize(out: $stdout, chdir: nil, env: {})
      @out = out
      @chdir = chdir
      @env = env
    end

    # Streams the command's output and returns it with the exit status. A command that cannot be
    # started (missing executable) reports status 127, as a shell would. `env` adds to (or, with a
    # nil value, removes from) the environment for this command only.
    def run(*argv, echo: true, quiet: false, env: {})
      argv = argv.flatten.map(&:to_s)
      @out.puts "+ #{display(argv)}" if echo
      output = +""
      options = {}
      options[:chdir] = @chdir if @chdir
      Open3.popen2e(@env.merge(env), *argv, **options) do |stdin, stream, wait|
        stdin.close
        stream.each_line do |line|
          output << line
          @out.print line unless quiet
        end
        Result.new(status: wait.value.exitstatus || 1, output: output)
      end
    rescue Errno::ENOENT, Errno::EACCES => e
      @out.puts "#{argv.first}: #{e.message}"
      Result.new(status: 127, output: e.message)
    end

    private

    # The command as a shell would need it typed, quoting only words that need it.
    def display(argv)
      argv.map { |arg| arg.match?(%r{\A[\w@%+=:,./-]+\z}) ? arg : Shellwords.escape(arg) }.join(" ")
    end
  end
end
