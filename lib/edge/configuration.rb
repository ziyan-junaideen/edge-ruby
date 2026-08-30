# frozen_string_literal: true

module Edge
  # Settings for a client. `Edge.configure` mutates the default instance;
  # `Edge::Client.new` takes the same options directly and freezes its own copy.
  class Configuration
    DEFAULT_BASE_URL = "https://api.tryedge.io"

    # Generous enough for a payment authorisation round trip, short enough that
    # a wedged request does not hold a web worker open indefinitely.
    DEFAULT_TIMEOUT = 30
    DEFAULT_OPEN_TIMEOUT = 10

    # A ceiling on `auto_paging_each`, independent of the loop detection that
    # already stops a cycle. A server bug should not be able to spin inside a
    # caller's request.
    DEFAULT_MAX_AUTO_PAGES = 1_000

    # Two extra attempts, so a transient blip costs at most three requests.
    DEFAULT_MAX_RETRIES = 2
    DEFAULT_RETRY_BASE_DELAY = 0.5
    DEFAULT_MAX_RETRY_DELAY = 8.0

    attr_accessor :api_key, :timeout, :open_timeout, :max_auto_pages, :app_info, :connection,
                  :instrumenter, :retry_policy
    attr_reader :base_url, :max_retries, :retry_base_delay, :max_retry_delay

    def initialize
      # Through the writer, so the default is normalised on exactly the same
      # path as a caller-supplied one and cannot drift from it.
      self.base_url = DEFAULT_BASE_URL
      apply_defaults

      # nil means "ActiveSupport::Notifications if it is loaded, else nothing".
      @instrumenter = nil
      # nil means "build one from the settings above". Injectable so a suite
      # can supply a policy that does not really sleep.
      @retry_policy = nil
      @app_info = nil
      @connection = nil
    end

    # A negative delay makes Kernel#sleep raise, turning a recoverable blip
    # into an unrelated ArgumentError halfway through a retry.
    def non_negative(name, value)
      unless value.is_a?(Numeric) && !value.negative?
        raise ConfigurationError, "#{name} must be a non-negative number, got #{value.inspect}"
      end

      value
    end

    def apply_defaults
      @timeout = DEFAULT_TIMEOUT
      @open_timeout = DEFAULT_OPEN_TIMEOUT
      @max_auto_pages = DEFAULT_MAX_AUTO_PAGES
      @max_retries = DEFAULT_MAX_RETRIES
      @retry_base_delay = DEFAULT_RETRY_BASE_DELAY
      @max_retry_delay = DEFAULT_MAX_RETRY_DELAY
    end
    private :apply_defaults

    def base_url=(value)
      @base_url = normalize_base_url(value)
    end

    def max_retries=(value)
      unless value.is_a?(Integer) && !value.negative?
        raise ConfigurationError, "max_retries must be a non-negative Integer, got #{value.inspect}"
      end

      @max_retries = value
    end

    def retry_base_delay=(value)
      @retry_base_delay = non_negative(:retry_base_delay, value)
    end

    def max_retry_delay=(value)
      @max_retry_delay = non_negative(:max_retry_delay, value)
    end

    # Never prints the key. Configuration objects end up in exception messages
    # and console sessions, and a credential that leaks there leaks everywhere.
    def inspect
      key = api_key ? "[FILTERED]" : "nil"
      "#<#{self.class.name} base_url=#{@base_url.inspect} api_key=#{key}>"
    end
    alias to_s inspect

    private

    def normalize_base_url(value)
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
  end
end
