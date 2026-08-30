# frozen_string_literal: true

RSpec.describe "the resource classes" do
  describe Edge::Customer do
    it "maps to the customers contract" do
      expect(described_class.contract_name).to eq("customers")
      expect(described_class.json_api_type).to eq("customers")
    end

    it "reads the attributes the contract records" do
      customer = described_class.new(
        { "type" => "customers", "id" => "cus_1",
          "attributes" => { "email" => "ada@example.com", "name" => "Ada",
                            "phone_number" => "+441234567890" } }
      )

      expect([customer.email, customer.name, customer.phone_number])
        .to eq(["ada@example.com", "Ada", "+441234567890"])
    end

    it "reports whether the merchant has blocked the customer" do
      expect(described_class.new({ "attributes" => { "blocked_at" => nil } })).not_to be_blocked
      expect(described_class.new({ "attributes" => { "blocked_at" => "2026-08-30T00:00:00Z" } }))
        .to be_blocked
    end

    it "keeps personal data out of inspect" do
      customer = described_class.new(
        { "id" => "cus_1", "attributes" => { "email" => "ada@example.com", "name" => "Ada" } }
      )

      expect(customer.inspect).to eq('#<Edge::Customer id="cus_1" type=nil>')
      expect(customer.inspect).not_to include("ada@example.com")
    end
  end

  describe Edge::ConsumerAddress do
    it "maps to the consumer_addresses contract" do
      expect(described_class.contract_name).to eq("consumer_addresses")
    end

    it "reads the address lines the extractor once truncated" do
      # A character class without digits cut `line_1` and `line_2` out of the
      # generated field list entirely, and they are marked sensitive.
      address = described_class.new(
        { "attributes" => { "line_1" => "1 Example Street", "line_2" => "Flat 2",
                            "city" => "London", "zip" => "E1 6AN", "country" => "GB" } }
      )

      # Each reader against its own value: `all(be_a(String))` would pass with
      # every reader wired to the same attribute.
      expect(address.line_1).to eq("1 Example Street")
      expect(address.line_2).to eq("Flat 2")
      expect(address.city).to eq("London")
      expect(address.zip).to eq("E1 6AN")
      expect(described_class.attribute_names).to include("line_1", "line_2")
    end

    it "reports a discarded address without offering to discard one" do
      # The column exists server-side; no route does.
      expect(described_class.new({ "attributes" => { "discarded_at" => "x" } })).to be_discarded
      expect(described_class).not_to respond_to(:delete, :discard)
    end
  end

  describe Edge::PaymentMethod do
    let(:method) do
      described_class.new(
        { "type" => "payment_methods", "id" => "pm_1",
          "attributes" => { "last_four" => "4242", "expiry_month" => "12",
                            "expiry_year" => "2030", "card_bin" => "424242",
                            "card_pan_token" => "pan_secret",
                            "card_cvv_token" => "cvv_secret" } }
      )
    end

    it "reads the card details safe to show a cardholder" do
      expect(method.last_four).to eq("4242")
      expect(method.expiry).to eq(%w[12 2030])
    end

    it "exposes the vault tokens but keeps them out of inspect" do
      # They are not card numbers, but they authorise charges.
      expect(method.card_pan_token).to eq("pan_secret")
      expect(method.inspect).not_to include("pan_secret")
      expect(method.inspect).not_to include("cvv_secret")
    end

    it "marks both tokens sensitive in the contract, so they are redacted everywhere" do
      expect(Edge::Contract.sensitive_fields("payment_methods"))
        .to include("card_pan_token", "card_cvv_token")
    end
  end

  describe "registration" do
    it "resolves each class by its contract name, so relationships find them" do
      {
        "customers" => Edge::Customer,
        "consumer_addresses" => Edge::ConsumerAddress,
        "payment_methods" => Edge::PaymentMethod
      }.each { |name, klass| expect(Edge::Resource.for(name)).to be(klass) }
    end

    it "resolves a relationship to the declared class rather than a generated one" do
      client = Edge::Client.new(api_key: "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB")
      document = Edge::JSONAPI::Document.new(
        "data" => { "type" => "consumer_addresses", "id" => "adr_1",
                    "relationships" => {
                      "customer" => { "data" => { "type" => "customers", "id" => "cus_1" } }
                    } },
        "included" => [{ "type" => "customers", "id" => "cus_1",
                         "attributes" => { "email" => "ada@example.com" } }]
      )

      customer = Edge::ConsumerAddress.from(document, client: client).customer.resource

      expect(customer).to be_a(Edge::Customer)
      expect(customer.email).to eq("ada@example.com")
    end
  end
end
