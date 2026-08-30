# frozen_string_literal: true

require "faraday"
require "uri"

module Edge
  # An authenticated connection to the Edge API.
  #
  # This is the real object. `Edge.configure` exists for the common
  # single-merchant case and delegates to a default instance; anything holding
  # more than one merchant's credentials — a marketplace, a background job
  # processing several accounts — should build clients explicitly.
  class Client
    # The API speaks JSON:API and rejects anything else with a 406 or 415.
    MEDIA_TYPE = "application/vnd.api+json"

    # Anything with a scheme is treated as absolute and must pass the origin
    # check. Deliberately not `://`: `https:evil.example/x` and
    # `mailto:a@evil.example` carry a scheme without an authority, and matching
    # only the hierarchical form would route them to the relative branch where
    # `URI.join` returns them unchanged and unchecked.
    ABSOLUTE = /\A[a-z][a-z0-9+.-]*:/i

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

    def get(path, params: nil, headers: nil)
      request(:get, path, params: params, headers: headers)
    end

    def post(path, body: nil, params: nil, headers: nil)
      request(:post, path, body: body, params: params, headers: headers)
    end

    def patch(path, body: nil, params: nil, headers: nil)
      request(:patch, path, body: body, params: params, headers: headers)
    end

    # Joins a relative API path onto the configured base URL, or verifies an
    # absolute one against it.
    #
    # `URI.join` is not usable directly: a path with a leading slash would
    # discard the base's own path, and an absolute URL would replace the origin
    # outright. Both are how a caller-supplied or server-supplied string ends
    # up pointing somewhere the credential should never go.
    def url_for(path)
      candidate = path.to_s
      return verified_url(candidate) if candidate.match?(ABSOLUTE)

      URI.join(config.base_url, candidate.sub(%r{\A/+}, "")).to_s
    rescue URI::Error => e
      raise Error, "could not build a URL from #{candidate.inspect}: #{e.message}"
    end

    # True when `url` addresses the same scheme, host and effective port as the
    # configured base URL. Pagination links and redirects are checked against
    # this before the bearer token is attached to them.
    def same_origin?(url)
      origin(URI.parse(url.to_s)) == origin(URI.parse(config.base_url))
    rescue URI::Error
      false
    end

    # Never prints the key.
    def inspect
      "#<#{self.class.name} base_url=#{config.base_url.inspect} mode=#{mode.inspect}>"
    end
    alias to_s inspect

    private

    # Deliberately not public: a Faraday::Connection has no redacting
    # `inspect`, so exposing one would put whatever it holds into every
    # exception reporter and console session. Nothing secret is stored on it —
    # credentials go out per request — but the reader stays private so that
    # remains true by construction rather than by accident.
    def connection
      @connection ||= config.connection || build_connection
    end

    # Authentication, media type and user agent are applied per request rather
    # than baked into the connection. Two reasons, both load-bearing:
    #
    #   - an injected connection would otherwise send no credentials at all,
    #     silently, and every request would 401;
    #   - a connection carrying `Authorization` prints the live key from its
    #     own `inspect`, which reaches Sentry, `better_errors` and `pp`.
    def request(method, path, body: nil, params: nil, headers: nil)
      url = url_for(path)

      connection.run_request(method, url, body, request_headers(headers)) do |req|
        req.params.update(params) if params
        # Applied here too, so timeouts hold on an injected connection.
        req.options.timeout = config.timeout
        req.options.open_timeout = config.open_timeout
      end
    end

    def request_headers(extra)
      base = {
        "Authorization" => "Bearer #{config.api_key}",
        "Accept" => MEDIA_TYPE,
        "Content-Type" => MEDIA_TYPE,
        "User-Agent" => user_agent
      }
      extra ? base.merge(extra) : base
    end

    # Scheme and host are case-insensitive (RFC 3986 3.2.2). URI.parse
    # normalises the scheme but not the host, so the host is downcased here;
    # without this a legitimately differently-cased link is refused.
    def origin(uri)
      [uri.scheme&.downcase, uri.host&.downcase, uri.port]
    end

    def verified_url(url)
      raise InsecureRedirectError.new(url, config.base_url) unless same_origin?(url)

      normalize(url)
    end

    # Echoing the caller's string back would carry two things forward that
    # should not survive: host casing, which makes otherwise identical URLs
    # look different in logs and cache keys, and userinfo, which Faraday turns
    # into a Basic auth header. The host has already been checked, so nothing
    # here changes where the request goes.
    def normalize(url)
      uri = URI.parse(url)
      uri.password = nil
      uri.user = nil
      uri.host = uri.host.downcase if uri.host
      uri.to_s
    end

    def build_connection
      Faraday.new(request: { timeout: config.timeout, open_timeout: config.open_timeout }) do |f|
        f.adapter Faraday.default_adapter
      end
    end

    # The API marks User-Agent required. It does not require the caller to
    # identify their application, so a working default is always available and
    # application metadata is only ever appended.
    def user_agent
      [config.app_info, "edge-ruby/#{Edge::VERSION}", "ruby/#{RUBY_VERSION}"].compact.join(" ")
    end

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
