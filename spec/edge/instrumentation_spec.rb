# frozen_string_literal: true

# Collects events instead of forwarding them, with the same interface
# ActiveSupport::Notifications exposes.
class RecordingInstrumenter
  attr_reader :events

  def initialize = @events = []

  def instrument(name, payload)
    @events << [name, payload]
    yield if block_given?
  end
end

RSpec.describe Edge::Instrumentation do
  let(:instrumenter) { RecordingInstrumenter.new }
  let(:secret_key) { "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB" }
  let(:client) { Edge::Client.new(api_key: secret_key, instrumenter: instrumenter) }

  def payload = instrumenter.events.first.last

  describe ".path_template" do
    it "replaces a UUID with :id so events group by endpoint" do
      expect(described_class.path_template(
               "https://api.tryedge.io/v2/payment_demands/78f3ce12-8b4f-4f9e-9937-8f45fa86cb0c"
             )).to eq("/v2/payment_demands/:id")
    end

    it "keeps the action after an identifier" do
      expect(described_class.path_template(
               "https://api.tryedge.io/v2/payment_demands/" \
               "78f3ce12-8b4f-4f9e-9937-8f45fa86cb0c/confirm"
             )).to eq("/v2/payment_demands/:id/confirm")
    end

    it "leaves a collection path alone" do
      expect(described_class.path_template("https://api.tryedge.io/v2/customers"))
        .to eq("/v2/customers")
    end

    it "leaves long resource names alone" do
      # A length heuristic treated any segment of 16+ characters as an
      # identifier, which rewrote these to /v2/:id and merged endpoints that
      # have nothing to do with each other.
      {
        "/v2/personal_identifications" => "/v2/personal_identifications",
        "/v2/merchant_punitive_actions" => "/v2/merchant_punitive_actions",
        "/v2/financial_institutions" => "/v2/financial_institutions",
        "/v2/beneficial_owners" => "/v2/beneficial_owners",
        "/v1/meter_notifications" => "/v1/meter_notifications"
      }.each do |path, expected|
        expect(described_class.path_template("https://api.tryedge.io#{path}")).to eq(expected)
      end
    end

    it "templates an identifier that is not a UUID" do
      expect(described_class.path_template("https://api.tryedge.io/v2/customers/cus_12345"))
        .to eq("/v2/customers/:id")
    end

    it "does not mistake a relationship name for an identifier" do
      expect(described_class.path_template(
               "https://api.tryedge.io/v2/payment_demands/" \
               "78f3ce12-8b4f-4f9e-9937-8f45fa86cb0c/relationships/payment_method"
             )).to eq("/v2/payment_demands/:id/relationships/payment_method")
    end

    it "survives an unparseable URL" do
      expect(described_class.path_template("http://[bad")).to eq("(unparseable)")
    end
  end

  describe "the emitted event" do
    it "reports method, path template, status and duration" do
      stub_request(:get, "https://api.tryedge.io/v2/customers")
        .to_return(status: 200, body: "{}", headers: { "X-Request-Id" => "req_9" })

      client.get("v2/customers")

      expect(payload).to include(
        method: "GET", path: "/v2/customers", status: 200, retries: 0, request_id: "req_9"
      )
      expect(payload[:duration]).to be_a(Float)
    end

    it "records the error class when a request fails" do
      stub_request(:get, "https://api.tryedge.io/v2/customers")
        .to_return(status: 404, body: "{}", headers: { "X-Request-Id" => "req_abc" })

      expect { client.get("v2/customers") }.to raise_error(Edge::NotFoundError)

      # The request id matters most on the failure path, where it is what
      # correlates this event with the server's own logs.
      expect(payload).to include(error: "Edge::NotFoundError", status: 404,
                                 request_id: "req_abc")
    end

    it "marks an event even when the request is interrupted" do
      # Interrupt and SIGTERM are not StandardError. Emitting an event with no
      # :error key would let a subscriber book a payment killed mid-flight as
      # a clean request.
      allow(Edge::Response).to receive(:from_faraday).and_raise(Interrupt)
      stub_request(:get, "https://api.tryedge.io/v2/customers").to_return(status: 200, body: "{}")

      expect { client.get("v2/customers") }.to raise_error(Interrupt)

      expect(payload).to include(error: "Interrupt")
    end

    it "carries no credential, body or query string" do
      # These payloads are forwarded verbatim to APM vendors and log
      # aggregators. A filter value can be a customer's email address.
      stub_request(:post, "https://api.tryedge.io/v2/customers")
        .with(query: { "filter[email]" => "ada@example.com" })
        .to_return(status: 201, body: '{"data":{"id":"1"}}')

      client.post("v2/customers", body: '{"data":{"attributes":{"email":"ada@example.com"}}}',
                                  params: { "filter[email]" => "ada@example.com" })

      serialized = payload.inspect
      expect(serialized).not_to include(secret_key)
      expect(serialized).not_to include("ada@example.com")
      expect(serialized).not_to include("attributes")
    end

    it "counts retries" do
      stub_request(:get, "https://api.tryedge.io/v2/customers")
        .to_return({ status: 500, body: "boom" }, { status: 200, body: "{}" })

      Edge::Client.new(
        api_key: secret_key, instrumenter: instrumenter,
        retry_policy: Edge::RetryPolicy.new(max_retries: 2, base_delay: 0, max_delay: 0,
                                            sleeper: ->(_) {})
      ).get("v2/customers")

      expect(instrumenter.events.length).to eq(2)
      expect(instrumenter.events.map { |_, event| event[:retries] }).to eq([0, 1])
    end

    it "does not let a broken subscriber fail the request" do
      broken = Class.new do
        def instrument(_name, _payload) = raise("subscriber exploded")
      end.new
      stub_request(:get, "https://api.tryedge.io/v2/customers").to_return(status: 200, body: "{}")

      expect { Edge::Client.new(api_key: secret_key, instrumenter: broken).get("v2/customers") }
        .not_to raise_error
    end
  end

  describe "without an instrumenter" do
    it "emits nothing and does not require ActiveSupport" do
      stub_request(:get, "https://api.tryedge.io/v2/customers").to_return(status: 200, body: "{}")

      expect(defined?(ActiveSupport::Notifications)).to be_nil
      expect { Edge::Client.new(api_key: secret_key).get("v2/customers") }.not_to raise_error
      expect(instrumenter.events).to be_empty
    end
  end
end
