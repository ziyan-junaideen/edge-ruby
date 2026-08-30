# frozen_string_literal: true

RSpec.describe Edge::RetryPolicy do
  # A deterministic policy: no real sleeping, and jitter fixed at its maximum
  # unless an example supplies its own source of randomness.
  def policy(max_retries: 2, base_delay: 1.0, max_delay: 8.0, random: nil)
    described_class.new(
      max_retries: max_retries, base_delay: base_delay, max_delay: max_delay,
      sleeper: ->(_seconds) {}, random: random || instance_double(Random, rand: 1.0)
    )
  end

  def api_error(klass, headers: {})
    klass.new(status: 500, headers: headers, body: nil, errors: [])
  end

  describe "#retry?" do
    it "does not retry when the operation did not opt in" do
      # This is the whole safety property: a write is never replayed because
      # the transport felt like it. Only an operation whose server-side replay
      # contract is documented may opt in.
      expect(policy.retry?(error: Edge::ConnectionError.new("boom"), attempt: 1,
                           retriable: false)).to be(false)
    end

    it "retries a retriable operation on a connection failure" do
      expect(policy.retry?(error: Edge::ConnectionError.new("boom"), attempt: 1,
                           retriable: true)).to be(true)
    end

    it "retries on 5xx" do
      expect(policy.retry?(error: api_error(Edge::ServerError), attempt: 1,
                           retriable: true)).to be(true)
    end

    it "retries on 429" do
      expect(policy.retry?(error: api_error(Edge::RateLimitError), attempt: 1,
                           retriable: true)).to be(true)
    end

    it "does not retry a status that says the server already acted" do
      # A 409 means the idempotency key was reused with different attributes,
      # and a 422 means the request was rejected on its merits. Repeating
      # either cannot help and might charge someone twice.
      [Edge::ConflictError, Edge::InvalidRequestError, Edge::NotFoundError,
       Edge::AuthenticationError, Edge::PermissionError].each do |klass|
        expect(policy.retry?(error: api_error(klass), attempt: 1, retriable: true))
          .to be(false), "#{klass} should not be retried"
      end
    end

    it "stops after max_retries" do
      error = Edge::ConnectionError.new("boom")

      expect(policy(max_retries: 2).retry?(error: error, attempt: 2, retriable: true)).to be(true)
      expect(policy(max_retries: 2).retry?(error: error, attempt: 3, retriable: true)).to be(false)
    end

    it "never retries when max_retries is zero" do
      expect(policy(max_retries: 0).retry?(error: Edge::ConnectionError.new("boom"),
                                           attempt: 1, retriable: true)).to be(false)
    end
  end

  describe ".safe_method?" do
    it "treats reads as safe to repeat" do
      expect(described_class.safe_method?(:get)).to be(true)
      expect(described_class.safe_method?("HEAD")).to be(true)
    end

    it "does not treat writes as safe" do
      expect(described_class.safe_method?(:post)).to be(false)
      expect(described_class.safe_method?(:patch)).to be(false)
      expect(described_class.safe_method?(:delete)).to be(false)
    end
  end

  describe "#delay_for" do
    it "backs off exponentially" do
      subject = policy(base_delay: 1.0)
      error = Edge::ConnectionError.new("boom")

      expect(subject.delay_for(error: error, attempt: 1)).to eq(1.0)
      expect(subject.delay_for(error: error, attempt: 2)).to eq(2.0)
      expect(subject.delay_for(error: error, attempt: 3)).to eq(4.0)
    end

    it "caps the backoff" do
      subject = policy(base_delay: 1.0, max_delay: 3.0)

      expect(subject.delay_for(error: Edge::ConnectionError.new("boom"), attempt: 10)).to eq(3.0)
    end

    it "jitters, so clients that failed together do not retry together" do
      spread = instance_double(Random)
      allow(spread).to receive(:rand).and_return(0.25)
      subject = policy(base_delay: 4.0, random: spread)

      expect(subject.delay_for(error: Edge::ConnectionError.new("boom"), attempt: 1)).to eq(1.0)
    end

    describe "Retry-After" do
      it "honours delta-seconds" do
        error = api_error(Edge::RateLimitError, headers: { "retry-after" => "5" })

        expect(policy.delay_for(error: error, attempt: 1)).to eq(5)
      end

      it "honours the HTTP-date form" do
        # RFC 9110 permits either. A client that handles only the integer form
        # ignores the date form and hammers a server that asked it not to.
        error = api_error(Edge::RateLimitError,
                          headers: { "retry-after" => (Time.now + 4).httpdate })

        expect(policy.delay_for(error: error, attempt: 1)).to be_between(3, 5)
      end

      it "matches the header case-insensitively" do
        error = api_error(Edge::RateLimitError, headers: { "Retry-After" => "3" })

        expect(policy.delay_for(error: error, attempt: 1)).to eq(3)
      end

      it "caps an unreasonable request" do
        error = api_error(Edge::RateLimitError, headers: { "retry-after" => "3600" })

        expect(policy.delay_for(error: error, attempt: 1))
          .to eq(described_class::MAX_HONOURED_RETRY_AFTER)
      end

      it "ignores a past date rather than waiting a negative time" do
        error = api_error(Edge::RateLimitError,
                          headers: { "retry-after" => (Time.now - 60).httpdate })

        expect(policy.delay_for(error: error, attempt: 1)).to eq(1.0)
      end

      it "falls back to backoff for an unparseable value" do
        error = api_error(Edge::RateLimitError, headers: { "retry-after" => "soon" })

        expect(policy.delay_for(error: error, attempt: 1)).to eq(1.0)
      end

      it "falls back to backoff when there is no response at all" do
        expect(policy.delay_for(error: Edge::ConnectionError.new("boom"),
                                attempt: 1)).to eq(1.0)
      end
    end
  end
end
