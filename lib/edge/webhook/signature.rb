# frozen_string_literal: true

require "openssl"

module Edge
  module Webhook
    # The `edge-signature` header: reading one, and computing the digest it
    # should have carried.
    #
    # Its own module because parsing a header a hostile party controls is a
    # distinct job from deciding whether a delivery is acceptable, and because
    # every question worth asking of this file is about the parser.
    module Signature
      # Plain decimal digits only, checked before `Integer` sees them. Ruby's
      # `Integer()` also accepts `0x68b5` and `1_756_742_400`, and the server
      # emits neither — so accepting them means a header whose `t=` reads one
      # way to this client and another to everything else looking at it, for
      # no gain. What is signed is the parsed value, so this is not a freshness
      # bypass; it is one fewer way for two readers to disagree.
      TIMESTAMP = /\A\d{1,19}\z/
      private_constant :TIMESTAMP

      class << self
        # `[timestamp, provided_digest]`, or raises.
        #
        # Unknown tokens are ignored rather than treated as malformed: the
        # server documents rolling out a future scheme by sending both for a
        # migration window (`t=…,v3=…,v4=…`).
        def parse!(header)
          pairs = tokenize(header)
          reject_duplicates!(pairs)

          tokens = pairs.to_h
          reject_legacy!(tokens)
          [timestamp!(tokens), tokens.fetch(SCHEME) { reject_unsigned!(tokens) }]
        end

        # HMAC-SHA256 over `"<timestamp>.<raw body>"`, lowercase hex — the
        # server's `:crypto.mac(:hmac, :sha256, secret, …) |> Base.encode16(case: :lower)`.
        def digest(body, secret, timestamp)
          OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
        end

        private

        def tokenize(header)
          header.to_s.split(",").filter_map do |token|
            name, _, value = token.strip.partition("=")
            [name, value] unless name.empty? || value.empty?
          end
        end

        # A repeated name is refused, not resolved. `Array#to_h` keeps the last
        # value, so `v3=<junk>,v3=<valid>` would verify while
        # `v3=<valid>,v3=<junk>` would not — the same header meaning two things
        # depending on reading order. That is the parser differential that
        # becomes a real bypass the moment anything else in the chain, a proxy
        # or a WAF or a log scanner, reads the first occurrence instead of the
        # last. There is one right answer to a duplicate and it is no.
        def reject_duplicates!(pairs)
          repeated = pairs.map(&:first).tally.select { |_, count| count > 1 }.keys
          return if repeated.empty?

          raise SignatureVerificationError,
                "#{HEADER} repeats #{repeated.sort.join(", ")}. A header that means one thing " \
                "read left to right and another read right to left is not one this client " \
                "will guess at."
        end

        # A v1/v2 header is a bare Base64 digest — no `t=`, no `v3=` — so it
        # would otherwise fail as "malformed" and send the reader looking for a
        # typo instead of at their delivery version.
        def reject_legacy!(tokens)
          return if tokens.key?("t") || tokens.key?(SCHEME)

          raise SignatureVerificationError,
                "this does not look like an #{HEADER} value. If it came from #{LEGACY_HEADER}, " \
                "the merchant is on webhook delivery v1 or v2, whose header is a constant " \
                "digest of the secret key and does not authenticate the body at all — there is " \
                "nothing to verify. This client verifies #{SCHEME} only; ask Edge to move the " \
                "merchant to v3."
        end

        def timestamp!(tokens)
          offered = tokens["t"].to_s
          return Integer(offered, 10) if offered.match?(TIMESTAMP)

          raise SignatureVerificationError,
                "#{HEADER} carries no usable timestamp; expected `t=<unix seconds>` in decimal."
        end

        def reject_unsigned!(tokens)
          raise SignatureVerificationError,
                "#{HEADER} carries no #{SCHEME} signature; it offered #{tokens.keys.inspect}. " \
                "This client verifies #{SCHEME} only."
        end
      end
    end
  end
end
