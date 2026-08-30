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

    # Whether names are checked against contract/manifest.yml before a request
    # is sent: filter, sort and include names on a read, attribute names on a
    # write. Off by default, because the manifest is generated and one that had
    # fallen behind the server would refuse a field that really does exist.
    #
    # Worth turning on in development, where the alternative feedback is a
    # mistyped filter fetching an entire table, or a mistyped attribute
    # returning 200 and changing nothing.
    attr_accessor :strict
    # Faraday SSL options, passed through to the adapter. The case this exists
    # for is a development instance behind a private CA: Ruby's OpenSSL reads
    # its own trust store (`OpenSSL::X509::DEFAULT_CERT_FILE`) and never
    # consults the macOS keychain, so a `mkcert -install`ed root is invisible
    # to it however well the browser and curl behave.
    #
    #   config.ssl = { ca_file: "#{`mkcert -CAROOT`.strip}/rootCA.pem" }
    #
    # Ignored when a connection is injected, which carries its own.
    #
    # Options that switch verification off are refused by Client for any host
    # but loopback and .test/.local — see `tls_verification_disabled?`. The
    # check lives there rather than here so that it sees the finished pair,
    # whichever order base_url and ssl were assigned in.
    attr_reader :ssl, :base_url, :max_retries, :retry_base_delay, :max_retry_delay

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
      @strict = false
      @ssl = nil
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
      @base_url = BaseUrl.normalize(value)
    end

    def ssl=(value)
      unless value.nil? || value.is_a?(Hash)
        raise ConfigurationError, "ssl must be a Hash, got #{value.inspect}"
      end

      @ssl = value&.transform_keys(&:to_sym)&.freeze
    end

    # True when `ssl` would leave the client unable to tell the host it meant
    # to reach from any other host that answers.
    #
    # Three options do that, and checking only the obvious one is how a guard
    # comes to be believed rather than effective. Faraday's Net::HTTP adapter
    # reads `verify_mode` first and only falls back to `verify`
    # (`adapter/net_http.rb:179`), so `verify_mode: OpenSSL::SSL::VERIFY_NONE`
    # bypasses `verify` entirely — and VERIFY_NONE is 0, which is truthy in
    # Ruby. `verify_hostname: false` keeps the chain check and drops the part
    # that says the certificate belongs to this host.
    def tls_verification_disabled?
      return false unless @ssl

      @ssl[:verify] == false ||
        @ssl[:verify_hostname] == false ||
        @ssl[:verify_mode] == OpenSSL::SSL::VERIFY_NONE
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
  end
end
