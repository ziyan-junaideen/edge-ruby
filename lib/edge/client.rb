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

      raw = connection.run_request(method, url, body, request_headers(headers)) do |req|
        apply_request_options(req, params)
      end

      Response.from_faraday(raw).raise_on_error!
    rescue Faraday::Error => e
      # `cause: nil` is load-bearing. Raising inside a rescue would otherwise
      # attach the Faraday error as `cause`, and Faraday::Error#inspect renders
      # the whole request including the Authorization header. Exception
      # reporters and Exception#full_message both walk the cause chain, so the
      # credential would reach them despite the message being scrubbed.
      raise transport_error(method, url, e), cause: nil
    end

    # Faraday::Error#inspect renders the whole request, Authorization header
    # included. Only the message is carried forward, scrubbed, and the original
    # is dropped rather than retained as `cause`.
    def transport_error(method, url, error)
      # The Faraday message frequently re-embeds the full URL, query string and
      # all, so it is scrubbed rather than trusted.
      detail = Redaction.scrub_query(Redaction.scrub(error.message.to_s))

      ConnectionError.new(
        "#{method.to_s.upcase} #{redacted_url(url)} failed: #{detail}",
        cause_class: error.class.name
      )
    end

    # The path only. A query string can carry customer data — an email being
    # filtered on, for instance — and this string ends up in exception
    # trackers.
    def redacted_url(url)
      uri = URI.parse(url)
      "#{uri.scheme}://#{uri.host}#{uri.path}"
    rescue URI::Error
      "the request URL"
    end

    def apply_request_options(req, params)
      req.params.update(params) if params
      # Applied per request, so timeouts hold on an injected connection too.
      req.options.timeout = config.timeout
      req.options.open_timeout = config.open_timeout
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
