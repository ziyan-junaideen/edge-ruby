# frozen_string_literal: true

require "json"

module Edge
  # Turns a Faraday response into either a parsed JSON:API document or the
  # right Edge exception.
  #
  # The API is not uniformly JSON. Auth failures return a bare reason phrase as
  # text/plain (http_authorization_plug.ex:30-50), and a proxy or load balancer
  # can return HTML for a 502. Parsing is therefore always attempted and never
  # assumed: a body that is not JSON must still produce a useful typed error,
  # not a JSON::ParserError from inside the client.
  class Response
    attr_reader :status, :headers, :raw_body

    def initialize(status:, headers:, body:)
      @status = status
      @headers = normalize_headers(headers)
      @raw_body = body
    end

    def self.from_faraday(response)
      new(status: response.status, headers: response.headers, body: response.body)
    end

    def success? = status.between?(200, 299)

    # The parsed body, or nil when it was empty or not JSON. Never raises.
    def data
      return @data if defined?(@data)

      @data = parse
    end

    # Raises the appropriate Edge error unless the response succeeded.
    def raise_on_error!
      return self if success?

      raise error_class.new(status: status, headers: headers, body: raw_body, errors: error_objects)
    end

    private

    def error_class
      ERROR_STATUSES.fetch(status) { status >= 500 ? ServerError : APIError }
    end

    def error_objects
      body = data
      return [] unless body.is_a?(Hash) && body["errors"]

      JSONAPI::ErrorObject.from(body)
    end

    def parse
      return nil if raw_body.nil?
      return raw_body if raw_body.is_a?(Hash) || raw_body.is_a?(Array)

      # Through Redaction.safe first: a proxy can return latin-1 bytes under a
      # utf-8 content type, and String#strip alone raises ArgumentError on
      # those — turning a server error into a crash inside the client, which is
      # exactly what this method promises not to do.
      text = Redaction.safe(raw_body.to_s)
      return nil if text.strip.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    # Faraday gives back a case-insensitive header set, but a client can be
    # constructed with an injected connection or a test double that yields a
    # plain Hash. Downcasing here means lookups behave the same either way.
    def normalize_headers(headers)
      return {} if headers.nil?

      headers.each_with_object({}) { |(key, value), result| result[key.to_s.downcase] = value }
    end
  end
end
