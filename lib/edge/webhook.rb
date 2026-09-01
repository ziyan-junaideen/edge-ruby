# frozen_string_literal: true

require "openssl"
require "json"

module Edge
  # Verifying a webhook delivery from Edge, and turning it into an event.
  #
  #   post "/webhooks/edge" do
  #     event = Edge::Webhook.construct_event(
  #       request.body.read,                        # the raw bytes, unparsed
  #       request.env["HTTP_EDGE_SIGNATURE"],
  #       ENV.fetch("EDGE_WEBHOOK_SECRET")
  #     )
  #     ProcessEdgeEvent.perform_later(event.id)    # see "Deduplicate" below
  #     status 200
  #   end
  #
  # ## What a valid signature does and does not tell you
  #
  # It tells you the body was produced by someone holding the subscription's
  # `secret_key` and has not been altered, and that it was signed within the
  # tolerance window.
  #
  # **It does not tell you the delivery is new.** Edge retries a failed
  # delivery, and a subscription can be redelivered by hand; both carry a
  # signature that verifies, and both are inside the window. Nothing in the
  # scheme prevents a replay — the timestamp bounds how long a captured
  # delivery stays useful, it does not make one single-use. **Deduplicate on
  # `event.id`** and make your handler idempotent. That is not belt and
  # braces; it is the only thing standing between a retry and a second
  # fulfilment.
  #
  # ## Only v3 is verifiable
  #
  # A merchant's `webhook_delivery_version` decides the scheme. `v3` is the one
  # above. `v1` and `v2` send `x-hub-signature: Base64(SHA1(secret_key))`,
  # which is constant for the life of the subscription and does not take the
  # body as an input — the server's own comment calls it "not a signature in
  # any meaningful sense". This module implements v3 and nothing else, on
  # purpose: a `verify_v1` would be a method whose name promises something it
  # cannot do. Passing a v1/v2 header here raises with an explanation rather
  # than a mismatch.
  module Webhook
    # The header the signature arrives on. Rack upcases and prefixes it:
    # `request.env["HTTP_EDGE_SIGNATURE"]`, or `request.headers["edge-signature"]`
    # in Rails.
    HEADER = "edge-signature"

    # The legacy header, recognised only so the error can say what happened.
    LEGACY_HEADER = "x-hub-signature"

    # The signature version this module verifies. The server documents that a
    # future scheme may be rolled out by sending both tokens for a migration
    # window (`t=…,v3=…,v4=…`), so the header is parsed as a set of tokens and
    # unknown ones are ignored rather than treated as malformed.
    SCHEME = "v3"

    # Five minutes, matching the usual convention. It bounds how long a
    # captured delivery is worth replaying; it does not prevent one.
    DEFAULT_TOLERANCE = 300

    class << self
      # Verifies the delivery and returns the event it carries.
      #
      # `payload` must be the **raw request body**, exactly as received. Not a
      # parsed Hash, not a re-encoded one: JSON key order is not stable, so
      # re-encoding the same data produces different bytes and the signature
      # will not match. In Rails read it before any parser touches it —
      # `request.raw_post`.
      def construct_event(payload, signature, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
        verify!(payload, signature, secret, tolerance: tolerance, now: now)
        Event.from(JSONAPI::Document.new(parse_payload(payload)))
      end

      # Verifies, and returns the `Time` the delivery was signed at — useful
      # for a staleness metric, and the reason this does not return a bare
      # true. Raises SignatureVerificationError on anything wrong.
      # `construct_event` is usually what you want; this is for a caller doing
      # its own parsing.
      def verify!(payload, signature, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
        timestamp, provided = Signature.parse!(signature)
        check_freshness!(timestamp, tolerance, now)
        expected = Signature.digest(raw_body!(payload), usable_secret!(secret), timestamp)

        reject_mismatch! unless OpenSSL.secure_compare(expected, provided)

        Time.at(timestamp).utc
      end

      # The `edge-signature` value for a payload, for use in **your own test
      # suite**. Building a delivery by hand otherwise means reimplementing
      # this file in your specs, and the two drift.
      #
      #   header = Edge::Webhook.test_signature(body, secret)
      def test_signature(payload, secret, timestamp: Time.now.to_i)
        timestamp = Integer(timestamp)
        body = raw_body!(payload)
        "t=#{timestamp},#{SCHEME}=#{Signature.digest(body, usable_secret!(secret), timestamp)}"
      end

      private

      def reject_mismatch!
        raise SignatureVerificationError,
              "webhook signature does not match. The body must be the raw bytes as received: " \
              "a re-encoded payload produces different bytes and cannot match. Check also " \
              "that this subscription's secret_key is the one signing it."
      end

      # Binary, so that the only thing this module ever raises is
      # SignatureVerificationError.
      #
      # It does not change the digest — UTF-8, ASCII-8BIT, ISO-8859-1 and even
      # invalid UTF-8 all hash to the same bytes either way, so this is not
      # about correctness of the signature. It is about a body in an encoding
      # that is not ASCII-compatible: `"#{timestamp}.#{body}"` on a UTF-16
      # string raises Encoding::CompatibilityError, which would escape a
      # webhook endpoint as a 500 rather than as the signature failure it is.
      def raw_body!(payload)
        unless payload.is_a?(String)
          raise SignatureVerificationError,
                "the payload must be the raw request body as a String, got #{payload.class}. " \
                "A parsed Hash cannot be verified: re-encoding it does not reproduce the bytes " \
                "that were signed."
        end

        payload.dup.force_encoding(Encoding::BINARY)
      end

      # An empty secret would otherwise produce a perfectly valid HMAC that any
      # attacker could also produce.
      #
      # Not forced to an encoding: the key is consumed as bytes and never
      # interpolated, so its encoding cannot affect the digest or raise. The
      # body is a different matter — see `raw_body!`.
      def usable_secret!(secret)
        secret = secret.to_s
        raise SignatureVerificationError, "no webhook secret_key given" if secret.empty?

        secret
      end

      # Both directions, so a receiver whose clock runs fast does not silently
      # accept deliveries signed arbitrarily far in the future.
      #
      # `tolerance` and `now` are coerced rather than trusted. A caller
      # writing `tolerance: ENV["EDGE_WEBHOOK_TOLERANCE"]` hands over a String,
      # and `age <= "600"` raises ArgumentError — out of a webhook endpoint,
      # on every delivery, valid ones included. This module raises
      # SignatureVerificationError and nothing else.
      def check_freshness!(timestamp, tolerance, now)
        return if tolerance.nil?

        tolerance = seconds!(tolerance, "tolerance")
        age = (seconds!(now || Time.now.to_i, "now") - timestamp).abs
        return if age <= tolerance

        raise SignatureVerificationError,
              "webhook timestamp is #{age}s away from now, outside the #{tolerance}s tolerance. " \
              "The signature may still be genuine — check this server's clock before widening " \
              "the window."
      end

      # The parser's own message is dropped, not scrubbed. JSON::ParserError
      # quotes the offending input — "unexpected character: 'whsec_…' at line
      # 1" — and this exception class promises it never carries the body.
      # Keeping the class name says everything a reader needs.
      def seconds!(value, name)
        Integer(value.is_a?(Time) ? value.to_i : value)
      # FloatDomainError (from Integer(Float::NAN)) is a RangeError.
      rescue TypeError, ArgumentError, RangeError
        raise SignatureVerificationError,
              "#{name} must be a whole number of seconds, got #{value.inspect}."
      end

      def parse_payload(payload)
        JSON.parse(payload)
      rescue JSON::ParserError
        raise SignatureVerificationError,
              "webhook body verified but is not JSON. The signature was good, so this is a " \
              "payload problem rather than a credential one — capture the raw body yourself " \
              "if you need to see it."
      end
    end
  end
end
