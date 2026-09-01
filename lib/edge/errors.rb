# frozen_string_literal: true

module Edge
  # Raised when the client is asked to do something it cannot be configured to
  # do: a missing key, a publishable key on the server, an unusable base URL.
  class ConfigurationError < Error; end

  # The request never completed: a timeout, a DNS failure, a TLS problem. No
  # response exists, so nothing can be said about whether the server acted.
  # For a write, that ambiguity is the reason an idempotency key matters.
  class ConnectionError < Error
    attr_reader :cause_class

    def initialize(message, cause_class: nil)
      @cause_class = cause_class
      super(Redaction.scrub(message))
    end
  end

  # A webhook delivery whose signature did not verify, or which could not be
  # checked at all. Never carries the secret or the body — including the
  # payload's own bytes, which is why a JSON parse failure here reports the
  # class of problem and not the parser's message.
  class SignatureVerificationError < Error; end

  # Raised when a URL would take an authenticated request off the configured
  # origin. Following such a URL with the bearer token attached would hand the
  # credential to whoever supplied it.
  class InsecureRedirectError < Error
    attr_reader :url, :base_url

    def initialize(url, base_url)
      @url = url
      @base_url = base_url
      super("refusing to send credentials to #{origin_of(url)}; " \
            "the configured origin is #{origin_of(base_url)}")
    end

    private

    # Reduced to scheme, host and port. Never the path, query or userinfo: a
    # refused URL is attacker-supplied and may carry a credential of its own.
    def origin_of(url)
      uri = URI.parse(url.to_s)
      port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
      "#{uri.scheme}://#{uri.host}#{port}"
    rescue URI::Error
      "an unparseable URL"
    end
  end

  # The server answered, and said no.
  #
  # Everything needed to diagnose the failure is retained: status, headers, the
  # raw body, and the parsed JSON:API error objects when there were any. The
  # API does not always send JSON — auth failures come back as plain text
  # (http_authorization_plug.ex:30-50) — so `errors` may be empty while
  # `raw_body` still explains the problem.
  class APIError < Error
    # Bodies can be large and are attacker-influenced. Enough to diagnose,
    # not enough to fill a log.
    BODY_EXCERPT = 500

    attr_reader :status, :headers, :raw_body, :errors, :request_id

    def initialize(status:, headers: {}, body: nil, errors: [])
      @status = status
      @headers = headers || {}
      @raw_body = body
      @errors = errors
      @request_id = @headers.find { |name, _| name.to_s.downcase == "x-request-id" }&.last

      super(build_message)
    end

    # Maps `source.pointer` onto attribute names, so a 422 can be rendered
    # against a form:
    #
    #   { amount_cents: ["must be greater than zero"] }
    def errors_by_attribute
      errors.each_with_object({}) do |error, result|
        name = error.attribute
        next unless name

        message = error.detail || error.title || error.code
        next unless message

        (result[name.to_sym] ||= []) << message
      end
    end

    # Errors that name a query parameter rather than an attribute, e.g. a
    # rejected `page[limit]`.
    def errors_by_parameter
      errors.each_with_object({}) do |error, result|
        name = error.parameter
        next unless name

        message = error.detail || error.title || error.code
        next unless message

        (result[name] ||= []) << message
      end
    end

    private

    def build_message
      # Falls back to the body when the error objects carry nothing readable.
      # JSON:API makes title and detail optional, so a declined card can arrive
      # as `{"errors":[{"code":"card_declined"}]}` — discarding the body there
      # would leave a message with no diagnostic content at all.
      detail = errors.map(&:to_s).reject(&:empty?).join("; ")
      detail = excerpt if detail.empty?

      parts = ["HTTP #{status}"]
      parts << detail unless detail.to_s.empty?
      parts << "(request #{request_id})" if request_id
      parts.join(" ")
    end

    # Scrubbed and truncated.
    #
    # Structurally scrubbed when the body is JSON, so that every field the
    # contract marks sensitive — webhook secrets, merchant tokens, national ID
    # numbers, dates of birth, addresses — is filtered by name rather than
    # relying on a pattern happening to match it. A non-JSON body is echoed
    # as-is by the server and could carry anything, so it is scrubbed
    # textually.
    def excerpt
      text = Redaction.scrub_body(raw_body).strip
      return "" if text.empty?

      text.length > BODY_EXCERPT ? "#{text[0, BODY_EXCERPT]}..." : text
    end
  end

  class BadRequestError < APIError; end
  class AuthenticationError < APIError; end
  class PermissionError < APIError; end
  class NotFoundError < APIError; end
  class NotAcceptableError < APIError; end
  class ConflictError < APIError; end
  class UnsupportedMediaTypeError < APIError; end
  class InvalidRequestError < APIError; end
  class RateLimitError < APIError; end
  class ServerError < APIError; end

  # Status to exception. 429 is not documented by the API, but an undocumented
  # limiter should surface as a rate limit rather than an opaque server error.
  ERROR_STATUSES = {
    400 => BadRequestError,
    401 => AuthenticationError,
    403 => PermissionError,
    404 => NotFoundError,
    406 => NotAcceptableError,
    409 => ConflictError,
    415 => UnsupportedMediaTypeError,
    422 => InvalidRequestError,
    429 => RateLimitError
  }.freeze
end
