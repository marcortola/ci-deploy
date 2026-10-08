# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module CiDeploy
  # Reads outputs from the current state of an HCP Terraform (or Terraform Enterprise) workspace
  # and exports them under the names a deploy configuration reads.
  #
  # The map has one entry per line, NAME=output, with two optional suffixes:
  #
  #   WEB_SERVER_IPS=web_server_ips            every element, comma-separated
  #   DATABASE_PRIVATE_IP=db_private_ips[0]    the first element only
  #   WORKER_SERVER_IPS=worker_server_ips?     may be missing or empty; exported as ""
  #
  # Lists are always written comma-separated, whatever their length, so one host and several
  # hosts reach the configuration in the same form (see CiDeploy::Hosts).
  class TerraformOutputs
    class Error < StandardError; end

    Entry = Struct.new(:name, :output, :first, :optional, keyword_init: true)

    LINE = /\A(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<output>[A-Za-z_][A-Za-z0-9_-]*)(?<first>\[0\])?(?<optional>\?)?\z/
    DEFAULT_ADDRESS = "https://app.terraform.io"
    RETRYABLE = [429, 500, 502, 503, 504].freeze

    def self.parse_map(text)
      entries = text.to_s.each_line.with_index(1).filter_map do |line, number|
        stripped = line.sub(/#.*/, "").strip
        next if stripped.empty?

        match = LINE.match(stripped)
        raise Error, "outputs map line #{number} is not NAME=output, NAME=output[0] or NAME=output?: #{stripped}" unless match

        Entry.new(name: match[:name], output: match[:output], first: !match[:first].nil?, optional: !match[:optional].nil?)
      end
      duplicates = entries.map(&:name).tally.select { |_name, count| count > 1 }.keys
      raise Error, "outputs map names #{duplicates.join(', ')} more than once" if duplicates.any?

      entries
    end

    def initialize(token:, workspace:, address: nil, http: nil, attempts: 3, delay: 5, sleeper: ->(seconds) { sleep(seconds) })
      @token = token.to_s
      @workspace = workspace.to_s
      @address = (address.to_s.empty? ? DEFAULT_ADDRESS : address.to_s).chomp("/")
      @http = http || method(:net_http_get)
      @attempts = attempts
      @delay = delay
      @sleeper = sleeper
    end

    # Returns [{name => value}, [sensitive names]].
    def resolve(entries)
      return [{}, []] if entries.empty?
      raise Error, "an outputs map was given without a Terraform token" if @token.empty?
      raise Error, "an outputs map was given without a Terraform workspace id" if @workspace.empty?
      unless @workspace.match?(/\Aws-[A-Za-z0-9]+\z/)
        raise Error, "the Terraform workspace id must look like ws-XXXXXXXX"
      end

      outputs = fetch
      values = {}
      sensitive = []
      entries.each do |entry|
        output = outputs[entry.output]
        value = output && convert(entry, output["value"])
        if value.nil? || value.empty?
          raise Error, "Terraform output '#{entry.output}' (for #{entry.name}) is missing or empty in workspace #{@workspace}. Has the workspace been applied?" unless entry.optional

          value = ""
        end
        values[entry.name] = value
        sensitive << entry.name if output && output["sensitive"]
      end
      [values, sensitive]
    end

    private

    def convert(entry, value)
      case value
      when nil
        nil
      when Array
        elements = value.flatten.map { |element| scalar(entry, element) }
        entry.first ? elements.first.to_s : elements.join(",")
      else
        raise Error, "Terraform output '#{entry.output}' is not a list, so [0] does not apply" if entry.first

        scalar(entry, value)
      end
    end

    def scalar(entry, element)
      case element
      when String, Numeric, true, false
        string = element.to_s
        if string.match?(/[\s,]/) && !string.empty?
          raise Error, "Terraform output '#{entry.output}' holds an element with whitespace or a comma, which a host list cannot carry"
        end

        string
      else
        raise Error, "Terraform output '#{entry.output}' holds a nested object; map a list or a scalar output instead"
      end
    end

    def fetch
      uri = URI("#{@address}/api/v2/workspaces/#{@workspace}/current-state-version?include=outputs")
      status = nil
      body = nil
      @attempts.times do |attempt|
        begin
          status, body = @http.call(uri, {
            "Authorization" => "Bearer #{@token}",
            "Content-Type" => "application/vnd.api+json"
          })
        rescue SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => e
          status = 0
          body = e.class.name
        end
        break unless status == 0 || RETRYABLE.include?(status)

        @sleeper.call(@delay * (attempt + 1)) if attempt + 1 < @attempts
      end

      unless status == 200
        hint = case status
               when 401, 403 then "The token was refused; check the Terraform token secret."
               when 404 then "The workspace or its state was not found; check the workspace id and that it has been applied."
               when 0 then "Terraform could not be reached (#{body})."
               else "Terraform answered with an error; re-running later usually fixes it."
               end
        raise Error, "Terraform answered HTTP #{status} to the state lookup, so the outputs are unknown and nothing was changed. #{hint}"
      end

      document = begin
        JSON.parse(body)
      rescue JSON::ParserError
        raise Error, "Terraform answered HTTP 200 with a body that is not JSON, so the outputs are unknown and nothing was changed."
      end
      included = document.is_a?(Hash) ? document.fetch("included", []) : []
      included.each_with_object({}) do |item, outputs|
        attributes = item.is_a?(Hash) ? item["attributes"] : nil
        outputs[attributes["name"]] = attributes if attributes.is_a?(Hash) && attributes["name"]
      end
    end

    def net_http_get(uri, headers)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 15, read_timeout: 30) do |http|
        response = http.get(uri.request_uri, headers)
        [response.code.to_i, response.body.to_s]
      end
    end
  end
end
