# frozen_string_literal: true

require "monitor"

require_relative "edge/version"
require_relative "edge/error"
require_relative "edge/contract"
require_relative "edge/redaction"
require_relative "edge/json_api/error_object"
require_relative "edge/json_api/identifier"
require_relative "edge/json_api/document"
require_relative "edge/errors"
require_relative "edge/response"
require_relative "edge/retry_policy"
require_relative "edge/request"
require_relative "edge/transport"
require_relative "edge/instrumentation"
require_relative "edge/api_key"
require_relative "edge/url_resolver"
require_relative "edge/base_url"
require_relative "edge/configuration"
require_relative "edge/client"
require_relative "edge/query/values"
require_relative "edge/query/path_checker"
require_relative "edge/query/filters"
require_relative "edge/query"
require_relative "edge/relationship"
require_relative "edge/list_object"
require_relative "edge/operations"
require_relative "edge/resource/definition"
require_relative "edge/resource/custom_actions"
require_relative "edge/resource"
require_relative "edge/resources/customer"
require_relative "edge/resources/consumer_address"
require_relative "edge/resources/payment_method"
require_relative "edge/resources/payment_demand"
require_relative "edge/resources/refund_demand"
require_relative "edge/resources/event"
require_relative "edge/resources/webhook_subscription"
require_relative "edge/resources/webhook_delivery"
require_relative "edge/webhook"
require_relative "edge/webhook/signature"

# An unofficial Ruby client for the Edge Payment Technologies HTTP API.
#
# Not published, supported or certified by Edge Payment Technologies. See
# README.md for what the API can and cannot do, and docs/release-blockers.md
# for the gaps that constrain this client's surface.
module Edge
  LOCK = Monitor.new
  private_constant :LOCK

  class << self
    # Configures the default client, for applications that talk to one
    # merchant. Anything holding several merchants' credentials should build
    # `Edge::Client` instances instead of relying on process-wide state.
    #
    #   Edge.configure do |config|
    #     config.api_key = ENV.fetch("EDGE_SECRET_KEY")
    #   end
    #
    # The configuration object is a local, never module state: holding it on
    # the module would keep the credential reachable after this returns and
    # would let concurrent callers overwrite each other's settings.
    #
    # The new client is installed only once it has been built successfully, so
    # a rejected key leaves the previous configuration intact rather than
    # half-applied.
    def configure
      config = Configuration.new
      yield config
      client = Client.new(config: config)

      LOCK.synchronize { @default_client = client }
      self
    end

    # The client built by `configure`. Raises rather than inventing an
    # unauthenticated one.
    def default_client
      LOCK.synchronize { @default_client } ||
        raise(ConfigurationError,
              "Edge is not configured; call Edge.configure or pass an explicit client")
    end

    def configured?
      LOCK.synchronize { !@default_client.nil? }
    end

    # Drops the default client. Intended for test suites, which should not
    # leak configuration between examples.
    def reset!
      LOCK.synchronize { @default_client = nil }
      self
    end
  end
end
