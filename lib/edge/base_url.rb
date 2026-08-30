# frozen_string_literal: true

require "uri"

module Edge
  # Deciding whether a string is a base URL this client may send credentials
  # to, and normalising it into a form that joins predictably.
  #
  # Split out of Configuration because it is a self-contained set of rules with
  # its own reasons — most of them security rather than tidiness — and
  # Configuration is otherwise where every unrelated setting accumulates.
  module BaseUrl
    module_function

    def normalize(value)
      raise ConfigurationError, "base_url cannot be nil" if value.nil?

      uri = parse_base_url(value)
      validate_base_url!(uri, value)

      # Store with exactly one trailing slash so joining a relative path is
      # predictable: URI.join against ".../v2" would discard the last segment.
      "#{uri.to_s.sub(%r{/+\z}, "")}/"
    end

    def validate_base_url!(uri, value)
      unless uri.is_a?(URI::HTTP) && uri.host
        raise ConfigurationError, "base_url must be an absolute http(s) URL, got #{value.inspect}"
      end

      # A query or fragment on a base URL is always a mistake, and a silent
      # one: appending the trailing slash after them produces a base whose own
      # path then evaporates on join, sending every request to the wrong place.
      if uri.query || uri.fragment
        raise ConfigurationError,
              "base_url must not carry a query or fragment, got #{value.inspect}"
      end

      reject_userinfo!(uri)
      reject_cleartext!(uri, value)
    end

    def reject_userinfo!(uri)
      return unless uri.userinfo

      raise ConfigurationError, "base_url must not carry credentials in its userinfo"
    end

    def parse_base_url(value)
      URI.parse(value.to_s)
    rescue URI::Error => e
      raise ConfigurationError, "base_url is not a valid URL (#{e.message}): #{value.inspect}"
    end

    # This client carries a bearer token that authorises money movement, so
    # cleartext is refused except where it can only be a local development
    # setup. Edge's own dev hosts are HTTPS on *.tryedge.test.
    def reject_cleartext!(uri, value)
      return unless uri.scheme == "http"
      return if uri.host.match?(Client::LOCAL_HOST)

      raise ConfigurationError,
            "base_url must use https so the API key is not sent in cleartext; " \
            "http is allowed only for loopback and .test/.local hosts, got #{value.inspect}"
    end

    # `normalize` is the entry point; the rest were private on Configuration
    # and stay that way, so extracting the cluster did not widen the surface.
    private_class_method :validate_base_url!, :reject_userinfo!, :parse_base_url,
                         :reject_cleartext!
  end
end
