# frozen_string_literal: true

RSpec.describe Edge::Relationship do
  before do
    stub_const("CustomerResource", Class.new(Edge::Resource) { contract "customers" })
    stub_const("AddressResource", Class.new(Edge::Resource) { contract "consumer_addresses" })
    stub_const("MerchantResource", Class.new(Edge::Resource) { contract "merchants" })
    # No manual registry writes: declaring the contract is what registers a
    # class, and that side effect is the thing these examples rely on. Putting
    # the entries in by hand would mask its removal entirely.
  end

  let(:client) { Edge::Client.new(api_key: "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB") }
  let(:base) { "https://api.tryedge.io" }

  # Exactly what the server sends: a belongs-to carries linkage, a to-many
  # carries a link and nothing else (phoenix_jsonapi/resource.ex:130-181).
  let(:payload) do
    {
      "type" => "customers", "id" => "cus_1",
      "attributes" => { "email" => "ada@example.com" },
      "relationships" => {
        "merchant" => {
          "data" => { "type" => "merchants", "id" => "mer_1" },
          "links" => { "self" => "#{base}/v2/customers/cus_1/relationships/merchant" }
        },
        "addresses" => {
          "links" => { "self" => "#{base}/v2/customers/cus_1/relationships/addresses" }
        }
      }
    }
  end

  let(:document) do
    Edge::JSONAPI::Document.new(
      "data" => payload,
      "included" => [{ "type" => "merchants", "id" => "mer_1",
                       "attributes" => { "business_name" => "Acme" } }]
    )
  end

  let(:customer) { CustomerResource.from(document, client: client) }

  describe "a belongs-to that carries linkage" do
    subject(:relationship) { customer.merchant }

    it "is reached by a reader generated from the contract" do
      expect(relationship).to be_a(described_class)
      expect(relationship.name).to eq("merchant")
    end

    it "reports the related id and type without a request" do
      expect(relationship.id).to eq("mer_1")
      expect(relationship.type).to eq("merchants")
      expect(relationship.identifier)
        .to eq(Edge::JSONAPI::Identifier.new(type: "merchants", id: "mer_1"))
    end

    it "is loaded, and not to-many" do
      expect(relationship).to be_loaded
      expect(relationship).not_to be_many
    end

    it "resolves the record from the same document, as the right class" do
      # Through the manifest's view name, not the reported type: a type can
      # belong to another resource entirely (RB-3).
      expect(relationship.resource).to be_a(MerchantResource)
      expect(relationship.resource.business_name).to eq("Acme")
    end

    it "carries the client forward, so the record can fetch in turn" do
      expect(relationship.resource.client).to be(client)
    end
  end

  describe "a to-many, which the API never links" do
    subject(:relationship) { customer.addresses }

    it "reports itself as unloaded, whatever include: asked for" do
      # The server sends no `data` for a to-many even when the records travel
      # in `included` (resource.ex:130). See FU-11.
      expect(relationship).not_to be_loaded
      expect(relationship.identifiers).to eq([])
      expect(relationship.id).to be_nil
    end

    it "does not guess the records out of included" do
      # In a collection response every customer's addresses share one included
      # array with nothing tying them to a parent. Matching by type would give
      # every customer every address.
      compound = Edge::JSONAPI::Document.new(
        "data" => payload,
        "included" => [{ "type" => "consumer_addresses", "id" => "adr_1",
                         "attributes" => { "city" => "London" } }]
      )

      expect(CustomerResource.from(compound).addresses.resource).to be_nil
    end

    it "yields no single record even once the server does send linkage" do
      # Today this is moot — a to-many carries no `data` at all — so it is
      # asserted against a document the server does not send yet. Without a
      # fixture that carries linkage, the example above passes only because
      # there is nothing to resolve, which is not a test of anything.
      linked = Edge::JSONAPI::Document.new(
        "data" => payload.merge(
          "relationships" => {
            "addresses" => { "data" => [{ "type" => "consumer_addresses", "id" => "adr_1" }] }
          }
        ),
        "included" => [{ "type" => "consumer_addresses", "id" => "adr_1",
                         "attributes" => { "city" => "London" } }]
      )
      relationship = CustomerResource.from(linked).addresses

      expect(relationship).to be_many
      expect(relationship.identifiers.map(&:id)).to eq(["adr_1"])
      # #resource is the to-one accessor. A to-many must not quietly answer it
      # with whichever record happened to be first.
      expect(relationship.resource).to be_nil
      expect(relationship.identifier).to be_nil
    end

    it "still knows the link to follow" do
      expect(relationship.link).to eq("#{base}/v2/customers/cus_1/relationships/addresses")
    end
  end

  describe "#fetch" do
    it "gets a to-one as the related record" do
      # The relationship endpoint returns the full resource rather than the
      # resource linkage JSON:API specifies for this link. See FU-12.
      stub_request(:get, "#{base}/v2/customers/cus_1/relationships/merchant")
        .to_return(status: 200, body: JSON.generate(
          "data" => { "type" => "merchants", "id" => "mer_1",
                      "attributes" => { "business_name" => "Acme" } }
        ))

      merchant = customer.merchant.fetch

      expect(merchant).to be_a(MerchantResource)
      expect(merchant.business_name).to eq("Acme")
    end

    it "gets a to-many as a list" do
      stub_request(:get, "#{base}/v2/customers/cus_1/relationships/addresses")
        .to_return(status: 200, body: JSON.generate(
          "data" => [{ "type" => "consumer_addresses", "id" => "adr_1" },
                     { "type" => "consumer_addresses", "id" => "adr_2" }]
        ))

      addresses = customer.addresses.fetch

      expect(addresses).to be_a(Edge::ListObject)
      expect(addresses.map(&:id)).to eq(%w[adr_1 adr_2])
      # The element class, not just the ids: resolving the contract is the
      # part that can silently regress to an attribute-less base class.
      expect(addresses.first).to be_a(AddressResource)
      expect(addresses.first.city).to be_nil
    end

    it "reads the shape from the response, not from the contract" do
      # A manifest that has recorded the cardinality wrongly must not turn a
      # collection into a single record or the reverse.
      stub_request(:get, "#{base}/v2/customers/cus_1/relationships/merchant")
        .to_return(status: 200, body: JSON.generate("data" => []))

      expect(customer.merchant.fetch).to be_a(Edge::ListObject)
    end

    it "raises rather than guessing a URL when there is no link" do
      relationship = described_class.new("payer", {}, owner: customer)

      expect { relationship.fetch }.to raise_error(Edge::Error, /carries no link/)
    end

    it "reports a missing link before it worries about a client" do
      # An unset to-one is the common case. Complaining about configuration
      # for a relationship that has nothing to fetch sends the caller looking
      # in the wrong place.
      clientless = CustomerResource.new({ "id" => "cus_1" })

      expect { clientless.relationship(:merchant).fetch }
        .to raise_error(Edge::Error, /carries no link/)
    end

    it "refuses to fall back to the globally configured client" do
      # A record parsed without a client must not reach for whatever default
      # the process holds. For anything serving more than one merchant that is
      # another merchant's credential and another merchant's data.
      Edge.configure { |config| config.api_key = "ept_live_sQsnYGFoLvE2Qt7tmsvuDESB" }
      clientless = CustomerResource.from(document)

      expect { clientless.merchant.fetch }
        .to raise_error(Edge::ConfigurationError, /must never be fetched with another/)
    ensure
      Edge.reset!
    end

    it "does not follow a link to another origin" do
      # A relationship link is a URL the server chose. Following it attaches
      # this client's bearer token.
      hostile = { "links" => { "self" => "https://evil.example/v2/customers/cus_1" } }
      relationship = described_class.new("merchant", hostile, owner: customer)

      expect { relationship.fetch }.to raise_error(Edge::InsecureRedirectError)
    end
  end

  describe "a relationship the server did not send" do
    it "is a relationship that reports itself unloaded, not an error" do
      relationship = CustomerResource.new({}).relationship(:merchant)

      expect(relationship).not_to be_loaded
      expect(relationship.id).to be_nil
      expect(relationship.link).to be_nil
    end
  end

  describe "#loaded?" do
    # The distinction this class exists for. On today's API an unset to-one and
    # an unlinked one are the same bytes (FU-11), but the JSON:API meaning of
    # `"data": null` is "explicitly empty" and it must not be read as "not
    # told" — a client that conflated them would report a demand as having no
    # payer when the server had simply not said.
    it "is true for explicitly null linkage" do
      relationship = described_class.new("merchant", { "data" => nil })

      expect(relationship).to be_loaded
      expect(relationship.identifier).to be_nil
    end

    it "is false when the member is absent" do
      expect(described_class.new("merchant", { "links" => { "self" => "/x" } }))
        .not_to be_loaded
    end
  end

  describe "#meta" do
    it "reads what the server annotated the relationship with" do
      relationship = described_class.new("merchant", { "meta" => { "role" => "payer" } })

      expect(relationship.meta).to eq("role" => "payer")
    end

    it "is an empty hash when there is none, or when it is not a hash" do
      expect(described_class.new("merchant", {}).meta).to eq({})
      expect(described_class.new("merchant", { "meta" => 42 }).meta).to eq({})
    end
  end

  describe "#inspect" do
    it "names the relationship without printing the document" do
      expect(customer.merchant.inspect)
        .to eq('#<Edge::Relationship merchant loaded=true id="mer_1">')
    end
  end

  describe "readers" do
    it "covers every relationship the contract records" do
      expect(CustomerResource.relationship_names)
        .to eq(Edge::Contract.resource("customers")["relationships"].keys)
    end

    it "makes no request, however far the caller reads into it" do
      # The entire reason relationships are not lazy proxies: a loop over 500
      # orders reading `order.payer` must not become 500 round trips. The stub
      # exists so that a request would succeed — the assertion is that none
      # was made, not that none could be.
      stub_request(:get, %r{https://api\.tryedge\.io/.*})
        .to_return(status: 200, body: '{"data":{"id":"mer_1","type":"merchants"}}')

      %i[merchant addresses].each do |name|
        relationship = customer.public_send(name)
        [relationship.id, relationship.type, relationship.identifier,
         relationship.identifiers, relationship.link, relationship.resource]
      end

      expect(a_request(:get, %r{https://api\.tryedge\.io/.*})).not_to have_been_made
    end
  end
end
