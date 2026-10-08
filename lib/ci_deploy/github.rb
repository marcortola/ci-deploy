# frozen_string_literal: true

require "securerandom"

module CiDeploy
  # Writes to the files GitHub Actions reads between steps. Outside Actions (tests without the
  # variables) the writes go nowhere and values stay in this process only.
  class Github
    def initialize(env: ENV, out: $stdout)
      @env = env
      @out = out
    end

    # Exports to later steps and to this process. Multiline values use the delimiter form, with a
    # delimiter the value cannot contain, so a value can never inject another variable.
    def set_env(name, value)
      @env[name] = value.to_s
      append("GITHUB_ENV", entry(name, value.to_s))
    end

    def set_output(name, value)
      append("GITHUB_OUTPUT", entry(name, value.to_s))
    end

    # Each line of a multiline secret is masked on its own, because the runner masks per line.
    # The value is escaped as workflow-command data, so a `%` or a lone carriage return reaches
    # the runner as the character itself, never as an escape or the end of the command.
    def mask(value)
      value.to_s.each_line(chomp: true) do |line|
        @out.puts "::add-mask::#{escape_data(line)}" unless line.strip.empty?
      end
    end

    def notice(message) = @out.puts("::notice::#{message}")
    def warning(message) = @out.puts("::warning::#{message}")
    def error(message) = @out.puts("::error::#{message}")

    private

    def escape_data(text) = text.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")

    def entry(name, value)
      unless name.match?(/\A[A-Za-z_][A-Za-z0-9_-]*\z/)
        raise ArgumentError, "invalid variable or output name: #{name.inspect}"
      end

      delimiter = "CI_DEPLOY_EOF_#{SecureRandom.hex(16)}"
      delimiter = "CI_DEPLOY_EOF_#{SecureRandom.hex(16)}" while value.include?(delimiter)
      "#{name}<<#{delimiter}\n#{value}\n#{delimiter}\n"
    end

    def append(variable, text)
      path = @env.fetch(variable, "")
      return if path.empty?

      File.open(path, "a") { |file| file.write(text) }
    end
  end
end
