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
    it "reads the route segment the contract is keyed by" do
      expect(request.resource_name).to eq("customers")
    end
  end
end
