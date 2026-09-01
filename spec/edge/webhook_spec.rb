# frozen_string_literal: true

RSpec.describe Edge::Webhook do
  # A delivery body in the shape `deliver_webhook_job.ex` sends for v3:
  # `{"data": {…event resource…}}`, with the five attributes `event_resource/1`
  # emits and no created_at.
  let(:body) do
    JSON.generate(
      "data" => {
        "id" => "evt_1", "type" => "events",
        # The shape `record_event/3` stores and `event_resource/1` delivers:
        # the event code is split, `resource_type` carrying the domain and
        # route name and `slug` carrying only the verb. Copied from the
        # server's own documented table (`views/events.ex:16-30`) and from the
        # `events_member` example in contract/openapi.json — not invented,
        # which is how the first version of this fixture hid a real bug.
        "attributes" => {
          "mode" => "sandbox", "resource_type" => "transaction.payment_demands",
          "resource_id" => "pd_1", "slug" => "succeeded",
          "data" => { "id" => "pd_1", "amount_cents" => 500 }
        },
        "relationships" => { "merchant" => { "data" => { "id" => "mer_1",
                                                         "type" => "merchants" } } }
      }
    )
  end

  let(:secret) { "whsec_TestSecret" }
  let(:now) { 1_756_742_400 }
  let(:header) { described_class.test_signature(body, secret, timestamp: now) }

  describe "the wire format" do
    # The load-bearing test in this file. The digest below was computed by an
    # independent implementation — Elixir's :crypto.mac/4, the same call the
    # server makes — over a payload with multi-byte UTF-8 in both the secret
    # and the body:
    #
    #   :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}")
    #   |> Base.encode16(case: :lower)
    #
    # Every other example here is self-consistent: they sign with this file's
    # own code and then verify with it, so they would all pass together if the
    # scheme were wrong. This one cannot.
    it "matches the server's HMAC byte for byte" do
      elixir_secret = "whsec_TestSecret_éß"
      elixir_body = '{"data":{"id":"evt_1","type":"events","attributes":' \
                    '{"slug":"transaction.payment_demands.succeeded",' \
                    '"data":{"amount":"5.00 €"}}}}'

      expect(described_class.test_signature(elixir_body, elixir_secret, timestamp: 1_756_742_400))
        .to eq("t=1756742400," \
               "v3=04a017e658e40d32dfa5e557b2ff4d96ecc99555166cc97419850aa86b67ae21")
    end

    it "signs the timestamp and body joined by a dot, not the body alone" do
      # Changing the timestamp must change the digest, or the freshness check
      # is decorative: an attacker could re-date a captured delivery.
      first = described_class.test_signature(body, secret, timestamp: now)
      second = described_class.test_signature(body, secret, timestamp: now + 1)

      expect(first).not_to eq(second)
    end
  end

  describe ".construct_event" do
    it "returns the event the delivery carries" do
      event = described_class.construct_event(body, header, secret, now: now)

      expect(event).to be_a(Edge::Event)
      expect(event.id).to eq("evt_1")
      expect(event.slug).to eq("succeeded")
      expect(event.code).to eq("transaction.payment_demands.succeeded")
      expect(event.data).to eq("id" => "pd_1", "amount_cents" => 500)
    end

    it "reads the relationship the delivery carries" do
      event = described_class.construct_event(body, header, secret, now: now)

      expect(event.merchant.id).to eq("mer_1")
    end

    it "does not return an event when the signature is wrong" do
      tampered = body.sub("500", "50000")

      expect { described_class.construct_event(tampered, header, secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /does not match/)
    end

    it "does not put the body in the error when it fails to parse" do
      # JSON::ParserError quotes the offending input — about thirty bytes of
      # it — and this exception class promises it never carries the body. The
      # parser's message is dropped rather than scrubbed.
      junk = "whsec_supersecret_value_here_and_more"
      signed = described_class.test_signature(junk, secret, timestamp: now)

      described_class.construct_event(junk, signed, secret, now: now)
    rescue Edge::SignatureVerificationError => e
      expect(e.message).not_to include("supersecret")
    end

    it "reports a verified body that is not JSON as such" do
      # Distinguishable from a signature failure on purpose: the two send you
      # to completely different places.
      junk = "not json at all"
      signed = described_class.test_signature(junk, secret, timestamp: now)

      expect { described_class.construct_event(junk, signed, secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /verified but is not JSON/)
    end
  end

  describe ".verify!" do
    it "returns when the signature is good, with the time it was signed" do
      expect(described_class.verify!(body, header, secret, now: now)).to eq(Time.at(now).utc)
    end

    it "rejects a body altered by one byte" do
      expect { described_class.verify!("#{body} ", header, secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /does not match/)
    end

    it "rejects a signature made with another subscription's secret" do
      other = described_class.test_signature(body, "whsec_SomeoneElse", timestamp: now)

      expect { described_class.verify!(body, other, secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /does not match/)
    end

    it "rejects a wrong signature of the right length" do
      # A same-length mismatch, so the rejection cannot be coming from a length
      # check standing in for the comparison.
      wrong = header.sub(/v3=(.)/) { "v3=#{Regexp.last_match(1) == "0" ? "1" : "0"}" }

      expect(wrong.length).to eq(header.length)
      expect { described_class.verify!(body, wrong, secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /does not match/)
    end

    it "never puts the secret in the error" do
      # These messages reach exception trackers and log aggregators.
      described_class.verify!(body, header, "whsec_NotTheOne", now: now)
    rescue Edge::SignatureVerificationError => e
      expect(e.message).not_to include("whsec_NotTheOne")
      expect(e.message).not_to include(secret)
    end
  end

  describe "freshness" do
    it "accepts a delivery inside the window" do
      expect { described_class.verify!(body, header, secret, now: now + 299) }.not_to raise_error
    end

    it "rejects one older than the tolerance" do
      expect { described_class.verify!(body, header, secret, now: now + 301) }
        .to raise_error(Edge::SignatureVerificationError, /outside the 300s tolerance/)
    end

    it "rejects one signed too far in the future" do
      # A receiver whose clock runs fast must not silently accept deliveries
      # dated arbitrarily far ahead.
      expect { described_class.verify!(body, header, secret, now: now - 301) }
        .to raise_error(Edge::SignatureVerificationError, /outside the 300s tolerance/)
    end

    it "honours a caller's own window" do
      expect { described_class.verify!(body, header, secret, tolerance: 600, now: now + 500) }
        .not_to raise_error
      expect { described_class.verify!(body, header, secret, tolerance: 10, now: now + 11) }
        .to raise_error(Edge::SignatureVerificationError)
    end

    it "raises nothing but SignatureVerificationError for a bad tolerance or clock" do
      # `tolerance: ENV["EDGE_WEBHOOK_TOLERANCE"]` hands over a String, and
      # `age <= "600"` is an ArgumentError — out of a webhook endpoint, on
      # every delivery, the valid ones included. Nothing here may raise
      # anything but SignatureVerificationError, and that has to be tested
      # with the values a caller will really pass.
      expect { described_class.verify!(body, header, secret, tolerance: "600", now: now) }
        .not_to raise_error
      expect { described_class.verify!(body, header, secret, now: Time.at(now)) }
        .not_to raise_error
      expect { described_class.verify!(body, header, secret, tolerance: 300.0, now: now) }
        .not_to raise_error
    end

    it "reports an unusable tolerance or clock as a verification failure" do
      expect { described_class.verify!(body, header, secret, tolerance: "soon", now: now) }
        .to raise_error(Edge::SignatureVerificationError, /tolerance must be a whole number/)
      expect { described_class.verify!(body, header, secret, now: Float::NAN) }
        .to raise_error(Edge::SignatureVerificationError, /now must be a whole number/)
      expect { described_class.verify!(body, header, secret, now: Object.new) }
        .to raise_error(Edge::SignatureVerificationError, /now must be a whole number/)
    end

    it "can be switched off entirely, which is a decision not a default" do
      expect { described_class.verify!(body, header, secret, tolerance: nil, now: now + 86_400) }
        .not_to raise_error
    end

    it "does not stop the same delivery verifying twice" do
      # The property that makes deduplication mandatory rather than advisable.
      # Edge retries failed deliveries and a subscription can be redelivered by
      # hand; both carry a signature that verifies, inside the window. Nothing
      # here makes a delivery single-use, and this example exists so that
      # nobody later mistakes the timestamp for replay protection.
      2.times do
        expect(described_class.verify!(body, header, secret, now: now + 10)).to be_a(Time)
      end
    end

    it "uses the real clock when no now: is given" do
      # Every other example pins `now`, so all of them would pass with the
      # freshness check reading a hardcoded time.
      fresh = described_class.test_signature(body, secret, timestamp: Time.now.to_i)
      stale = described_class.test_signature(body, secret, timestamp: Time.now.to_i - 3_600)

      expect { described_class.verify!(body, fresh, secret) }.not_to raise_error
      expect { described_class.verify!(body, stale, secret) }
        .to raise_error(Edge::SignatureVerificationError, /tolerance/)
    end
  end

  describe "headers it will not verify" do
    it "explains the legacy v1/v2 header rather than reporting a mismatch" do
      # `x-hub-signature` is Base64(SHA1(secret_key)): constant per
      # subscription, body not an input. Reported as "you are on v1/v2", not as
      # a bad signature, because those need completely different actions.
      # `pack("m0")` rather than Base64.strict_encode64: base64 left the
      # default gems in Ruby 3.4, and a spec is no reason to add a dependency.
      legacy = [OpenSSL::Digest::SHA1.digest(secret)].pack("m0")

      expect { described_class.verify!(body, legacy, secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /delivery v1 or v2/)
    end

    it "rejects an empty or missing header the same way" do
      [nil, "", "   "].each do |value|
        expect { described_class.verify!(body, value, secret, now: now) }
          .to raise_error(Edge::SignatureVerificationError, /does not look like/)
      end
    end

    it "rejects a header with a timestamp and no signature" do
      expect { described_class.verify!(body, "t=#{now}", secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /no v3 signature/)
    end

    it "rejects a header with a signature and no timestamp" do
      expect { described_class.verify!(body, "v3=abc", secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /no usable timestamp/)
    end

    it "rejects a non-numeric timestamp" do
      expect { described_class.verify!(body, "t=yesterday,v3=abc", secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /no usable timestamp/)
    end

    it "refuses a header that repeats a token" do
      # `to_h` keeps the last value, so `v3=<junk>,v3=<valid>` would verify
      # while `v3=<valid>,v3=<junk>` would not — one header meaning two things
      # depending on reading order. That is the differential that becomes a
      # bypass as soon as a proxy or a log scanner reads the first occurrence
      # instead of the last.
      mac = header.split("v3=").last

      ["t=#{now},v3=deadbeef,v3=#{mac}", "t=#{now},v3=#{mac},v3=deadbeef",
       "t=#{now},t=#{now},v3=#{mac}"].each do |repeated|
        expect { described_class.verify!(body, repeated, secret, now: now) }
          .to raise_error(Edge::SignatureVerificationError, /repeats/)
      end
    end

    it "refuses a timestamp Ruby would parse but the server never sends" do
      # `Integer()` accepts `0x68b5` and `1_756_742_400`. The server emits
      # neither, and accepting them means `t=` reads one way here and another
      # to everything else looking at the header.
      mac = header.split("v3=").last

      ["t=0x68b5,v3=#{mac}", "t=1_756_742_400,v3=#{mac}", "t= 175,v3=#{mac}"].each do |odd|
        expect { described_class.verify!(body, odd, secret, tolerance: nil) }
          .to raise_error(Edge::SignatureVerificationError, /decimal/)
      end
    end

    it "accepts the canonical spelling of that same timestamp" do
      # The control: the rejection above must be about the spelling, not about
      # the value or the tolerance argument.
      expect { described_class.verify!(body, header, secret, tolerance: nil) }.not_to raise_error
    end

    it "ignores an unknown scheme token beside a good v3" do
      # The server documents rolling out a future scheme by sending both for a
      # migration window. A client that called that malformed would break on
      # the day of the rollout.
      expect { described_class.verify!(body, "#{header},v4=deadbeef", secret, now: now) }
        .not_to raise_error
    end

    it "verifies v3 even when it is not the first token" do
      timestamp, scheme = header.split(",")

      expect { described_class.verify!(body, "#{scheme},#{timestamp}", secret, now: now) }
        .not_to raise_error
    end
  end

  describe "arguments it refuses" do
    it "refuses an already-parsed body" do
      # The mistake that costs an afternoon: `request.params` or a Hash from
      # `JSON.parse`. Key order is not stable, so re-encoding does not
      # reproduce the signed bytes and the signature can never match.
      expect { described_class.verify!(JSON.parse(body), header, secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /raw request body as a String/)
    end

    it "refuses an empty secret" do
      # An empty key still produces a valid HMAC — one anybody can produce.
      [nil, ""].each do |value|
        expect { described_class.verify!(body, header, value, now: now) }
          .to raise_error(Edge::SignatureVerificationError, /no webhook secret_key/)
      end
    end
  end

  describe "encodings" do
    it "verifies a body carrying multi-byte characters" do
      # Without forcing both sides to binary the HMAC raises
      # Encoding::CompatibilityError, which would crash on some payloads and
      # not others.
      attributes = { "data" => { "name" => "Ada Löve—lace" } }
      utf8 = JSON.generate("data" => { "id" => "evt_1", "type" => "events",
                                       "attributes" => attributes })
      signed = described_class.test_signature(utf8, "sécret", timestamp: now)

      expect { described_class.verify!(utf8, signed, "sécret", now: now) }.not_to raise_error
    end

    it "reports a body in a non-ASCII-compatible encoding as a signature failure" do
      # The one case the binary forcing exists for. Interpolating a UTF-16
      # string into the signed payload raises Encoding::CompatibilityError,
      # which would leave a webhook endpoint answering 500 instead of
      # rejecting the delivery. Nothing here may raise anything but
      # SignatureVerificationError.
      utf16 = body.encode(Encoding::UTF_16LE)

      expect { described_class.verify!(utf16, header, secret, now: now) }
        .to raise_error(Edge::SignatureVerificationError, /does not match/)
    end

    it "hashes the same bytes whatever encoding they arrived tagged with" do
      # UTF-8, binary and ISO-8859-1 carrying the same bytes must produce the
      # same signature, or a body that survived a round trip through a
      # differently-configured proxy would stop verifying.
      %w[UTF-8 BINARY ISO-8859-1].each do |encoding|
        tagged = body.dup.force_encoding(encoding)

        expect(described_class.test_signature(tagged, secret, timestamp: now)).to eq(header)
      end
    end

    it "verifies a body handed over as binary, as Rack reads it" do
      binary = body.dup.force_encoding(Encoding::BINARY)

      expect { described_class.verify!(binary, header, secret, now: now) }.not_to raise_error
    end

    it "does not modify the payload it was given" do
      frozen = body.dup.freeze

      expect { described_class.verify!(frozen, header, secret, now: now) }.not_to raise_error
      expect(frozen.encoding).to eq(Encoding::UTF_8)
    end
  end
end
