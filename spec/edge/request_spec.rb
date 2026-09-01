# frozen_string_literal: true

RSpec.describe Edge::Request do
  let(:request) do
    described_class.new(
      verb: :post,
      url: "https://api.tryedge.io/v2/customers?filter%5Bemail%5D=ada@example.com",
      body: '{"data":{"type":"customers","attributes":{"email":"ada@example.com",' \
            '"name":"Ada Lovelace","phone_number":"+441234567890"}}}',
      headers: { "Authorization" => "Bearer ept_live_sQsnYGFoLvE2Qt7tmsvuDESB" },
      retriable: false
    )
  end

  describe "#inspect" do
    it "prints nothing a reporter should not have" do
      # A Struct prints every member by default. This object is live in
      # Transport's stack frames, so Sentry, better_errors or a pry transcript
      # would render the customer's email, name and phone alongside the bearer
      # token — from an object nobody thought of as a place secrets live.
      printed = request.inspect

      expect(printed).not_to include("ada@example.com")
      expect(printed).not_to include("Ada Lovelace")
      expect(printed).not_to include("+441234567890")
      expect(printed).not_to include("ept_live")
      expect(printed).not_to include("Bearer")
    end

    it "still says enough to identify the request" do
      expect(request.inspect)
        .to eq("#<Edge::Request POST https://api.tryedge.io/v2/customers?[FILTERED] " \
               "bytes=123 retriable=false>")
    end

    it "is what to_s uses too, so interpolation is safe as well" do
      expect(request.to_s).not_to include("ada@example.com")
    end
  end

  describe "#resource_name" do
    def name_for(path)
      described_class.new(verb: :post, url: "https://api.tryedge.io#{path}").resource_name
    end

    it "reads the route segment the contract is keyed by" do
      expect(request.resource_name).to eq("customers")
    end

    it "reads it from a member as well as a collection" do
      expect(name_for("/v2/customers")).to eq("customers")
      expect(name_for("/v2/customers/cus_1")).to eq("customers")
      expect(name_for("/v1/meter_ticks")).to eq("meter_ticks")
    end

    it "does not hand a sub-resource its parent's contract" do
      # `confirm` on a payment demand is a retry of a failed charge, so
      # replaying it charges again. Answering "payment_demands" here would
      # let it inherit that resource's `idempotent_writes` and be marked
      # retriable. Nil denies the lookup, and Transport refuses the write.
      expect(name_for("/v2/payment_demands/pd_1/confirm")).to be_nil
      expect(name_for("/v2/customers/cus_1/relationships/addresses")).to be_nil
    end

    it "refuses a path it cannot read rather than guessing at one" do
      expect(name_for("/customers")).to be_nil
      expect(name_for("/v2/")).to be_nil
      expect(name_for("/v2/customers/")).to be_nil
      expect(described_class.new(verb: :get, url: "http://[").resource_name).to be_nil
    end
  end

  describe "the replay guard this feeds" do
    let(:client) { Edge::Client.new(api_key: "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB") }

    it "refuses a retriable write to a custom action" do
      # The reason #resource_name stops at a member. refund_demands is the one
      # resource with a replay contract, so this is the strongest case: even
      # there, a sub-resource path must not inherit it.
      expect { client.patch("v2/refund_demands/rd_1/confirm", body: "{}", retriable: true) }
        .to raise_error(ArgumentError, /cannot be retried/)
    end

    it "still allows one on the resource itself, so the guard is not vacuous" do
      stub_request(:post, "https://api.tryedge.io/v2/refund_demands")
        .to_return(status: 201, body: '{"data":{"type":"refund_demands","id":"rd_1"}}')

      expect { client.post("v2/refund_demands", body: "{}", retriable: true) }.not_to raise_error
    end
  end
end
