# frozen_string_literal: true

require "json"

module Edge
  # Keeps credentials and personal data out of anything a human or a service
  # will read: exception messages, `inspect` output, log lines, instrumentation
  # payloads.
  #
  # The API returns webhook signing keys, merchant tokens and KYC identifiers
  # such as national ID numbers and dates of birth, and the request carries a
  # bearer token. None of that may appear in an error report.
  #
  # `#raw` on a resource is the deliberate exception: it hands back exactly
  # what the server sent, and its documentation says so.
  module Redaction
    FILTERED = "[FILTERED]"

    # Matches an Edge API key wherever it appears in free text — a URL a server
    # handed back, a message someone interpolated. The mode is kept because it
    # is useful when debugging and is not itself a secret.
    API_KEY = /\bept_(live|sandbox)_[1-9A-HJ-NP-Za-km-z]+/

    # Authorization header values. More schemes than this client sends, since
    # the text being scrubbed may have come from anywhere.
    #
    # "Token" is deliberately absent: it is an ordinary English word, and
    # including it swallowed "bad token ept_live_..." whole — over-redacting
    # the message and, worse, hiding the mode prefix that makes the remaining
    # text useful. The API key pattern already covers that case precisely.
    CREDENTIAL = /\b(Bearer|Basic|Digest|ApiKey)\s+\S+/i

    # A query string can carry customer data — an email being filtered on — and
    # these strings end up in exception trackers.
    QUERY_STRING = /(\?|&)[^\s"']+=[^\s"']*/

    class << self
      # Scrubs a string. Cheap enough to apply to every message that might
      # carry a credential, which is the point: it is applied by default rather
      # than at each call site's discretion.
      def scrub(text)
        return text unless text.is_a?(String)

        # Invalid bytes are replaced first. A proxy can return latin-1 under a
        # utf-8 content type, and a regex over those bytes raises ArgumentError
        # — turning a server error into a crash inside the client.
        safe(text)
          .gsub(API_KEY) { "ept_#{Regexp.last_match(1)}_#{FILTERED}" }
          .gsub(CREDENTIAL) { "#{Regexp.last_match(1)} #{FILTERED}" }
      end

      # Removes query strings from any URL in the text.
      def scrub_query(text)
        return text unless text.is_a?(String)

        safe(text).gsub(QUERY_STRING) { "#{Regexp.last_match(1)}#{FILTERED}" }
      end

      # A string that regexes can safely run over, whatever bytes arrived.
      def safe(text)
        text.valid_encoding? ? text : text.scrub("?")
      rescue ArgumentError
        text.dup.force_encoding(Encoding::BINARY).scrub("?")
      end

      # Scrubs a response body: structurally when it is JSON, so that fields
      # the contract marks sensitive are filtered by name, and textually
      # otherwise.
      def scrub_body(body)
        text = safe(body.to_s)
        parsed = begin
          JSON.parse(text)
        rescue JSON::ParserError
          nil
        end

        return scrub(text) if parsed.nil?

        JSON.generate(scrub_data(parsed))
      end

      # Replaces the values of sensitive keys in a nested structure. Key
      # matching is case-insensitive and ignores a leading JSON Pointer path,
      # so both `"secret_key"` and `"/data/attributes/secret_key"` are caught.
      def scrub_data(value, sensitive: Contract.all_sensitive_fields)
        case value
        when Hash then scrub_hash(value, sensitive)
        when Array then value.map { |item| scrub_data(item, sensitive: sensitive) }
        when String then scrub(value)
        else value
        end
      end

      private

      def scrub_hash(hash, sensitive)
        hash.each_with_object({}) do |(key, nested), result|
          result[key] =
            if sensitive?(key, sensitive)
              FILTERED
            else
              scrub_data(nested, sensitive: sensitive)
            end
        end
      end

      def sensitive?(key, sensitive)
        name = key.to_s.downcase.split("/").last.to_s
        sensitive.include?(name)
      end
    end
  end
end
