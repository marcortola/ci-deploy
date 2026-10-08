# frozen_string_literal: true

require "yaml"

module CiDeploy
  # Builds Kamal invocations for one configuration and optional destination.
  class Kamal
    LOG_LINE = /\A\s*(DEBUG|INFO|WARN|ERROR|FATAL) /

    attr_reader :config, :destination

    def initialize(runner:, config:, destination: nil)
      @runner = runner
      @config = config.to_s
      @destination = destination.to_s
      raise ArgumentError, "no Kamal configuration file given" if @config.empty?
    end

    def argv(*args)
      ["kamal", *args.flatten.map(&:to_s), "-c", @config, *(@destination.empty? ? [] : ["-d", @destination])]
    end

    def run(*args, **options)
      @runner.run(argv(*args), **options)
    end

    # The version each app host reports, as {host => version}; "" where nothing runs. nil when the
    # query itself failed. Kamal prints "App Host: <host>", then that host's version, then a blank
    # line; with several hosts the writes can interleave with each other and with SSHKit's log
    # lines, so log lines are skipped and each version goes to the oldest host still waiting.
    def app_versions(echo: true)
      result = run("app", "version", echo: echo)
      return nil unless result.success?

      self.class.parse_app_versions(result.output)
    end

    def self.parse_app_versions(output)
      pending = []
      versions = {}
      skip_blank = false
      output.each_line(chomp: true) do |line|
        next if line.match?(LOG_LINE)

        if (match = line.match(/\AApp Host: (\S+)/))
          pending << match[1]
          versions[match[1]] = nil
          next
        end
        if skip_blank && line.empty?
          skip_blank = false
          next
        end
        next if pending.empty?

        versions[pending.shift] = line.strip
        skip_blank = true
      end
      versions.transform_values { |version| version.to_s }
    end

    # The fully qualified image reference Kamal would deploy for a version.
    def absolute_image(version)
      result = run("config", "--version", version, echo: true, quiet: true)
      raise Error, "kamal config failed, so the image reference is unknown:\n#{result.output}" unless result.success?

      document = result.output[result.output.index("---") || 0..]
      data = YAML.safe_load(document, permitted_classes: [Symbol])
      image = data.is_a?(Hash) && (data[:absolute_image] || data["absolute_image"])
      raise Error, "kamal config did not report an absolute image" if image.to_s.empty?

      image.to_s
    end

    class Error < StandardError; end
  end
end
