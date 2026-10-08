# frozen_string_literal: true

module CiDeploy
  # Reads host lists from the environment while Kamal renders a deploy configuration.
  #
  # The setup action writes every Terraform list output as one comma-separated value. Older
  # consumers joined them with spaces, and a value pasted by hand may carry newlines, so any mix
  # of commas and whitespace separates hosts here. One host and several hosts read the same way:
  #
  #   <% require "ci_deploy/hosts" %>
  #   hosts: <%= CiDeploy::Hosts.list("WEB_SERVER_IPS") %>
  #   host: <%= CiDeploy::Hosts.first("DATABASE_SERVER_IPS") %>
  module Hosts
    class MissingHosts < KeyError; end

    SEPARATOR = /[\s,]+/

    module_function

    # Every host in the variable, in order, without duplicates. Raises when the variable is unset
    # or holds no host, unless required is false, in which case the result is empty.
    def list(name, required: true, env: ENV)
      hosts = parse(env.fetch(name, ""))
      if hosts.empty? && required
        raise MissingHosts, "#{name} holds no host. Map it to a Terraform output in the setup action, or export it for the local launcher."
      end

      hosts
    end

    def first(name, env: ENV)
      list(name, env: env).first
    end

    def parse(value)
      value.to_s.split(SEPARATOR).reject(&:empty?).uniq
    end
  end
end
