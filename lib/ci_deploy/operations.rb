# frozen_string_literal: true

require "shellwords"

module CiDeploy
  # Free Kamal arguments, as typed into a workflow form. They are split the way a POSIX shell
  # splits words (quotes group, nothing else is special) and passed to Kamal as an argument vector:
  # no shell on the runner ever sees them, so `;`, `|`, `$()` and backticks are plain characters.
  module KamalArgs
    class Invalid < ArgumentError; end

    RESERVED = /\A(-c|--config-file|-d|--destination)(=.*)?\z|\A-[cd].+\z/

    module_function

    def parse(text)
      argv = Shellwords.split(text.to_s)
      argv.shift if argv.first == "kamal"
      raise Invalid, "no Kamal arguments given" if argv.empty?

      # The checks read the options as Thor will; Kamal still receives argv exactly as typed.
      options = expand(argv)
      reserved = options.find { |arg| arg.match?(RESERVED) }
      if reserved
        raise Invalid, "#{reserved} is set by the action's configuration and destination inputs, not by the free arguments"
      end
      filters = filter_values(options)
      empty = filters.find { |_option, value| value.split(",").all? { |item| item.strip.empty? } }
      raise Invalid, "#{empty.first} needs at least one value: an empty filter would select every host" if empty
      if targeted?(options) && filters.none? { |option, _value| option == "--hosts" }
        raise Invalid, "this command stops, replaces or removes the proxy or the application on every host it reaches: add --hosts with an explicit target"
      end

      argv
    rescue ArgumentError => e
      raise e if e.is_a?(Invalid)

      raise Invalid, "the Kamal arguments cannot be split: #{e.message}"
    end

    # Commands that interrupt every application behind a host's proxy, or remove an application:
    # `proxy reboot|restart|upgrade|stop|remove`, and `remove` and `upgrade` themselves. Options may
    # come before the subcommand, so any non-option word counts; a false match only asks for --hosts.
    TARGETED_PROXY = %w[reboot restart upgrade stop remove].freeze
    TARGETED_TOP = %w[remove upgrade].freeze

    def targeted?(argv)
      words = argv.reject { |arg| arg.start_with?("-") }
      proxy = words.index("proxy")
      return true if proxy && words.drop(proxy + 1).any? { |word| TARGETED_PROXY.include?(word) }

      words.any? { |word| TARGETED_TOP.include?(word) }
    end

    # Thor, Kamal's option parser, reads letters squished behind one dash as separate options:
    # `-yh` is `-y -h`, whose value is the next word. Only letters squish (`-h192.0.2.10` does
    # not), as in Thor.
    SQUISHED = /\A-([A-Za-z]{2,})\z/

    def expand(argv)
      argv.flat_map { |arg| (match = arg.match(SQUISHED)) ? match[1].chars.map { |letter| "-#{letter}" } : [arg] }
    end

    # Every --hosts/-h and --roles/-r filter as [canonical option, value], in the forms `--hosts=a,b`,
    # `--hosts a,b`, `-h=a,b`, `-h a,b` (Thor's) and `-ha,b`, which Thor leaves as an argument that
    # Kamal's commands then refuse. A separate value must be the next word and not an option: Thor
    # gives `-h` followed by an option or nothing no host list, so the value counts as empty.
    def filter_values(argv)
      names = { "--hosts" => "--hosts", "-h" => "--hosts", "--roles" => "--roles", "-r" => "--roles" }
      filters = []
      argv.each_with_index do |arg, index|
        if names.key?(arg)
          value = argv[index + 1].to_s
          filters << [names[arg], value.start_with?("-") ? "" : value]
        elsif (match = arg.match(/\A(--hosts|--roles)=(.*)\z/m))
          filters << [match[1], match[2]]
        elsif (match = arg.match(/\A-([hr])(.+)\z/m))
          filters << [names["-#{match[1]}"], match[2].delete_prefix("=")]
        end
      end
      filters
    end
  end

  # The common operations catalog. Each operation maps its inputs to one or more Kamal argument
  # vectors; inputs are validated here so a value cannot smuggle extra options into Kamal.
  class Operations
    ACCESSORY_VERBS = %w[boot reboot start stop restart details].freeze
    CATALOG = [
      *ACCESSORY_VERBS.map { |verb| "accessory-#{verb}" },
      "host-exec", "app-exec", "console", "logs",
      "proxy-details", "proxy-restart", "proxy-reboot",
      "kamal"
    ].freeze
    STACKS = { "none" => nil, "symfony" => "bin/console", "node" => "node", "python" => "python" }.freeze
    CONTAINER_MODES = %w[new-image live-container].freeze
    SERVERS = %w[primary all].freeze

    NAME = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/
    SELECTOR = /\A[A-Za-z0-9_.:*\[\]\/-]+(,[A-Za-z0-9_.:*\[\]\/-]+)*\z/

    class Invalid < ArgumentError; end

    def initialize(inputs)
      @in = inputs.transform_keys(&:to_s).transform_values { |value| value.to_s.strip }
    end

    def argvs
      operation = @in.fetch("operation", "")
      raise Invalid, "unknown operation #{operation.inspect}; expected one of: #{CATALOG.join(', ')}" unless CATALOG.include?(operation)

      case operation
      when /\Aaccessory-(.+)\z/ then [["accessory", Regexp.last_match(1), accessory_target]]
      when "host-exec" then [["server", "exec", *selection, required("command")]]
      when "app-exec" then [app_exec(stack(optional: true))]
      when "console" then [app_exec(stack(optional: false))]
      when "logs" then [logs]
      when "proxy-details" then [["proxy", "details", *hosts_option], ["proxy", "boot_config", "get", *hosts_option]]
      when "proxy-restart" then [["proxy", "restart", *explicit_proxy_target]]
      when "proxy-reboot" then [["proxy", "reboot", "-y", *explicit_proxy_target]]
      when "kamal" then [KamalArgs.parse(@in["args"].to_s.empty? ? @in["command"] : @in["args"])]
      end
    rescue KamalArgs::Invalid => e
      raise Invalid, e.message
    end

    private

    def required(name)
      value = @in.fetch(name, "")
      raise Invalid, "the #{name} input is required for #{@in['operation']}" if value.empty?

      value
    end

    def accessory_target
      target = required("target")
      raise Invalid, "accessory target #{target.inspect} is not an accessory name or 'all'" unless target.match?(NAME)

      target
    end

    def selection
      server = @in.fetch("server", "").then { |value| value.empty? ? "primary" : value }
      raise Invalid, "server must be one of #{SERVERS.join(', ')}, not #{server.inspect}" unless SERVERS.include?(server)

      [*("--primary" if server == "primary"), *roles_option, *hosts_option]
    end

    def roles_option
      roles = @in.fetch("roles", "")
      return [] if roles.empty?
      raise Invalid, "roles #{roles.inspect} must be a comma-separated list of role names" unless roles.match?(SELECTOR)

      ["--roles=#{roles}"]
    end

    def hosts_option
      hosts = @in.fetch("hosts", "")
      return [] if hosts.empty?
      raise Invalid, "hosts #{hosts.inspect} must be a comma-separated list of hosts" unless hosts.match?(SELECTOR)

      ["--hosts=#{hosts}"]
    end

    # Restarting or rebooting the proxy interrupts every application on the host, so the target is
    # never implied: either named hosts, or the literal `all`.
    def explicit_proxy_target
      hosts = @in.fetch("hosts", "")
      raise Invalid, "#{@in['operation']} needs an explicit target: set hosts to a comma-separated host list, or to 'all'" if hosts.empty?
      return [] if hosts == "all"

      hosts_option
    end

    def stack(optional:)
      name = @in.fetch("stack", "").then { |value| value.empty? ? "none" : value }
      raise Invalid, "stack must be one of #{STACKS.keys.join(', ')}, not #{name.inspect}" unless STACKS.key?(name)
      raise Invalid, "console needs a stack: #{STACKS.keys.reject { |key| key == 'none' }.join(', ')}" if !optional && name == "none"

      STACKS[name]
    end

    # The container mode is never defaulted. `new-image` runs a disposable container from the
    # deployed image; `live-container` execs into the running one (--reuse), which shares its
    # state - for Symfony, a console run as root there can leave the cache unwritable for php-fpm.
    def app_exec(prefix)
      mode = @in.fetch("container-mode", "")
      unless CONTAINER_MODES.include?(mode)
        raise Invalid, "container-mode must be chosen explicitly: #{CONTAINER_MODES.join(' or ')}"
      end

      command = required("command")
      ["app", "exec", *selection, *("--reuse" if mode == "live-container"), [prefix, command].compact.join(" ")]
    end

    def logs
      target = required("target")
      options = []
      lines = @in.fetch("lines", "")
      unless lines.empty?
        raise Invalid, "lines must be a positive number" unless lines.match?(/\A[1-9][0-9]*\z/)

        options += ["-n", lines]
      end
      since = @in.fetch("since", "")
      unless since.empty?
        raise Invalid, "since must look like 5m, 1h or an RFC 3339 timestamp" unless since.match?(/\A[0-9A-Za-z:.+-]+\z/)

        options += ["-s", since]
      end
      grep = @in.fetch("grep", "")
      unless grep.empty?
        # Kamal quotes the pattern in single quotes inside the remote command line.
        raise Invalid, "grep must not contain a single quote or a newline" if grep.match?(/['\n]/)

        options += ["-g", grep]
      end

      case target
      when "app" then ["app", "logs", *options, *roles_option, *hosts_option]
      when "proxy" then ["proxy", "logs", *options, *hosts_option]
      else
        raise Invalid, "log target #{target.inspect} is not app, proxy or an accessory name" unless target.match?(NAME)

        ["accessory", "logs", target, *options]
      end
    end
  end
end
