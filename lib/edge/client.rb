# frozen_string_literal: true

require "uri"

module Edge
  # An authenticated connection to the Edge API.
  #
  # This is the real object. `Edge.configure` exists for the common
  # single-merchant case and delegates to a default instance; anything holding
  # more than one merchant's credentials — a marketplace, a background job
  # processing several accounts — should build clients explicitly.
  class Client
    include Transport

    # Kept here as well as on Transport: it was public API before the split.
    MEDIA_TYPE = Transport::MEDIA_TYPE

    # Hosts for which cleartext HTTP is a development convenience rather than a
    # mistake. Everything else must be HTTPS: this client carries a bearer
    # token that authorises money movement.
    LOCAL_HOST = /\A(localhost|127(\.\d+){3}|\[?::1\]?|.+\.(test|local|localhost))\z/i

    attr_reader :config

    def initialize(api_key: nil, config: nil, **options)
      @config = (config || Configuration.new).dup
      @config.api_key = api_key if api_key
      options.each { |name, value| @config.public_send(:"#{name}=", value) }

      @parsed_key = validate!

      # Frozen so the credential cannot be swapped after validation. Mutating
      # it post-construction would let a publishable key past `validate!`, and
      # would desync `mode` from what is actually sent.
      @config.freeze
    end

    # `:live`, `:sandbox`, or nil when the credential is not a recognisable
    # Edge key. Nil is not a failure — OAuth bearer tokens authenticate too —
    # and it is deliberately not a guess.
    def mode = @parsed_key&.mode

    def sandbox? = mode == :sandbox
    def live? = mode == :live

    # `retriable:` on a read may only narrow: a read is safe to repeat by
    # definition, so passing false turns retries off for this call.
    def get(path, params: nil, headers: nil, retriable: nil)
      dispatch(build(:get, path, params: params, headers: headers, retriable: retriable))
    end

    # `retriable:` is how a write states that replaying it is safe. It defaults
    # to false and is never inferred; passing true for a resource whose replay
    # contract the API does not document raises. See Edge::RetryPolicy.
    def post(path, body: nil, params: nil, headers: nil, retriable: false)
      dispatch(build(:post, path, body: body, params: params, headers: headers,
                                  retriable: retriable))
    end

    def patch(path, body: nil, params: nil, headers: nil, retriable: false)
      dispatch(build(:patch, path, body: body, params: params, headers: headers,
                                   retriable: retriable))
    end

    # Joins a relative API path onto the configured base URL, or verifies an
    # absolute one against it. See Edge::UrlResolver.
    def url_for(path) = resolver.resolve(path)

    # True when `url` addresses the same origin as the configured base URL.
    # Pagination links and redirects are checked against this before the bearer
    # token is attached to them.
    def same_origin?(url) = resolver.same_origin?(url)

    # Never prints the key.
    def inspect
      "#<#{self.class.name} base_url=#{config.base_url.inspect} mode=#{mode.inspect}>"
    end
    alias to_s inspect

    private

    def resolver = @resolver ||= UrlResolver.new(config.base_url)

    def validate!
      raise ConfigurationError, "no api_key configured" if config.api_key.to_s.empty?

      key = ApiKey.parse(config.api_key)
      if key&.browser?
        raise ConfigurationError,
              "that is a publishable (browser) key, which cannot authenticate server-side " \
              "requests. Publishable keys are for the Edge.js browser SDK; use the secret " \
              "key from the same mode (#{key.mode}) here."
      end

      key
    end
  end
end
