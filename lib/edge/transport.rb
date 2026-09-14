# frozen_string_literal: true

require "faraday"

module Edge
  # The sending half of Client: building a request, dispatching it with
  # retries, instrumenting it, and turning transport failures into Edge errors.
  #
  # Separate from Client because it is a coherent unit with its own reasons —
  # replay safety and credential containment — and because Client otherwise
  # became the place where every unrelated concern accumulated.
  module Transport
    # The API speaks JSON:API and rejects anything else with a 406 or 415.
    MEDIA_TYPE = "application/vnd.api+json"

    private

    def build(verb, path, **)
      request = Request.new(verb: verb, url: url_for(path), **)
      reject_unsafe_replay!(request)
      request.freeze
    end

    # An operation may only opt into retries when the server documents that
    # replaying its idempotency key returns the original record instead of
    # acting again. The contract records exactly which resources do
    # (`idempotent_writes`), so this is checked rather than trusted.
    #
    # Without it, `retriable: true` on meter_ticks — whose key is documented as
    # merely *unique*, not replayable — would quietly authorise a double write.
    def reject_unsafe_replay!(request)
      return if request.safe? || !request.retriable

      resource = request.resource_name
      return if resource && Contract.resource(resource)&.fetch("idempotent_writes", false)

      raise ArgumentError,
            "#{request.verb.to_s.upcase} #{request.resource_name || request.url} cannot be " \
            "retried: the API documents no replay contract for it, so a repeated request " \
            "may act twice. See contract/manifest.yml (idempotent_writes)."
    end

    def dispatch(request)
      attempt = 0

      begin
        attempt += 1
        instrumented(request, attempt - 1) { send_once(request) }
      rescue *RetryPolicy::RETRYABLE => e
        # Splatted from the policy rather than hand-repeated: two lists that
        # must agree about when money may move twice is one list too many.
        raise e unless retries.retry?(error: e, attempt: attempt, retriable: request.retriable?)

        retries.wait(retries.delay_for(error: e, attempt: attempt))
        retry
      end
    end

    def instrumented(request, retry_count, &)
      Instrumentation.instrument(
        config.instrumenter, method: request.verb, url: request.url, retries: retry_count, &
      )
    end

    # The Request is sent unchanged on every attempt, so a replayed write
    # carries the identical body and idempotency key it started with.
    def send_once(request)
      raw = connection.run_request(
        request.verb, request.url, request.body, request_headers(request.headers)
      ) { |req| apply_request_options(req, request.params) }

      Response.from_faraday(raw).raise_on_error!
    rescue Faraday::Error => e
      # `cause: nil` is load-bearing. Raising inside a rescue would otherwise
      # attach the Faraday error as `cause`, and Faraday::Error#inspect renders
      # the whole request including the Authorization header. Exception
      # reporters and Exception#full_message both walk the cause chain, so the
      # credential would reach them despite the message being scrubbed.
      raise transport_error(request.verb, request.url, e), cause: nil
    end

    # Faraday::Error#inspect renders the whole request, Authorization header
    # included. Only the message is carried forward, scrubbed, and the original
    # is dropped rather than retained as `cause`.
    def transport_error(verb, url, error)
      # The Faraday message frequently re-embeds the full URL, query string and
      # all, so it is scrubbed rather than trusted.
      detail = Redaction.scrub_query(Redaction.scrub(error.message.to_s))

      ConnectionError.new(
        "#{verb.to_s.upcase} #{redacted_url(url)} failed: #{detail}",
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

    # Authentication, media type and user agent are applied per request rather
    # than baked into the connection. Two reasons, both load-bearing:
    #
    #   - an injected connection would otherwise send no credentials at all,
    #     silently, and every request would 401;
    #   - a connection carrying `Authorization` prints the live key from its
    #     own `inspect`, which reaches Sentry, `better_errors` and `pp`.
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
      options = { request: { timeout: config.timeout, open_timeout: config.open_timeout } }
      # Only when set, so the adapter keeps its own defaults otherwise rather
      # than being handed an empty hash to interpret.
      options[:ssl] = config.ssl if config.ssl
      Faraday.new(**options) do |f|
        f.adapter Faraday.default_adapter
      end
    end

    # The API marks User-Agent required. It does not require the caller to
    # identify their application, so a working default is always available and
    # application metadata is only ever appended.
    def user_agent
      [config.app_info, "edge-ruby/#{Edge::VERSION}", "ruby/#{RUBY_VERSION}"].compact.join(" ")
    end

    def retries
      @retries ||= config.retry_policy || RetryPolicy.new(
        max_retries: config.max_retries,
        base_delay: config.retry_base_delay,
        max_delay: config.max_retry_delay
      )
    end

    # Deliberately not public: a Faraday::Connection has no redacting
    # `inspect`, so exposing one would put whatever it holds into every
    # exception reporter and console session. Nothing secret is stored on it —
    # credentials go out per request — but the reader stays private so that
    # remains true by construction rather than by accident.
    def connection
      @connection ||= config.connection || build_connection
    end
  end
end
