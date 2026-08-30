# frozen_string_literal: true

RSpec.describe Edge::Resource do
  # Named rather than anonymous: `inspect` and NoMethodError messages both
  # print the class name, and those are what the examples below assert on.
  before do
    stub_const("CustomerResource", Class.new(described_class) { contract "customers" })
  end

  let(:payload) do
    {
      "type" => "customers",
      "id" => "cus_1",
      "attributes" => {
        "email" => "ada@example.com",
        "name" => "Ada Lovelace",
        "created_at" => "2026-08-30T12:00:00Z",
        "loyalty_tier" => "gold"
      },
      "relationships" => {
        "merchant" => { "data" => { "type" => "merchants", "id" => "mer_1" } }
      },
      "links" => { "self" => "https://api.tryedge.io/v2/customers/cus_1" },
      "meta" => { "version" => 3 }
    }
  end

  let(:resource) { CustomerResource.new(payload) }

  describe "contract-derived readers" do
    it "defines a reader for each attribute the manifest records" do
      expect(resource.email).to eq("ada@example.com")
      expect(resource.name).to eq("Ada Lovelace")
    end

    it "returns nil for an attribute the server did not send" do
      expect(CustomerResource.new({ "id" => "cus_1" }).email).to be_nil
    end

    it "raises on a misspelled reader rather than returning nil" do
      # This is the whole reason there is no method_missing: `amont_cents`
      # returning nil is how a client books a payment of nothing.
      expect { resource.emial }.to raise_error(NoMethodError, /emial/)
    end

    it "does not invent readers the contract does not list" do
      expect(resource).not_to respond_to(:loyalty_tier)
    end

    it "refuses a resource name the manifest does not have" do
      expect { Class.new(described_class) { contract "unicorns" } }
        .to raise_error(ArgumentError, %r{unicorns is not in contract/manifest.yml})
    end

    it "reports the JSON:API type the manifest records, which is not the route name" do
      # They diverge (docs/release-blockers.md, RB-3), so the two are read from
      # different places on purpose.
      institutions = Class.new(described_class) { contract "financial_institutions" }

      expect(institutions.contract_name).to eq("financial_institutions")
      expect(institutions.json_api_type).to eq("beneficial_owners")
    end
  end

  describe "unknown fields" do
    it "keeps an attribute the contract has never heard of" do
      # The server may ship a field before this gem knows about it. Dropping it
      # would make that invisible to everyone downstream.
      expect(resource["loyalty_tier"]).to eq("gold")
      expect(resource[:loyalty_tier]).to eq("gold")
    end

    it "lists what it did not recognise" do
      expect(resource.unknown_attributes).to eq(["loyalty_tier"])
    end

    it "distinguishes an absent attribute from one that is present and null" do
      resource = CustomerResource.new({ "attributes" => { "blocked_at" => nil } })

      expect(resource.key?("blocked_at")).to be(true)
      expect(resource.key?("email")).to be(false)
    end

    it "keeps the whole payload on #raw" do
      expect(resource.raw).to eq(payload)
    end
  end

  describe "values" do
    it "returns timestamps as the server sent them" do
      # Not coerced: parsing succeeds for a well-formed timestamp and fails for
      # anything else, and a reader whose class depends on the data is worse
      # than one that is merely inconvenient.
      expect(resource.created_at).to eq("2026-08-30T12:00:00Z")
    end

    it "exposes relationships, links and meta as sent" do
      expect(resource.relationships["merchant"]["data"]["id"]).to eq("mer_1")
      expect(resource.links["self"]).to end_with("/v2/customers/cus_1")
      expect(resource.meta).to eq("version" => 3)
    end

    it "defaults every member to an empty hash for a sparse payload" do
      resource = CustomerResource.new({})

      expect([resource.attributes, resource.relationships, resource.links,
              resource.meta]).to all(be_empty)
    end

    it "survives a payload that is not a hash" do
      expect(CustomerResource.new("nonsense").attributes).to eq({})
    end
  end

  describe "#to_h" do
    it "is the attributes, without identity folded over them" do
      expect(CustomerResource.new(payload).to_h).to eq(payload["attributes"])
    end

    it "is a copy, so callers can build on it" do
      hash = CustomerResource.from(Edge::JSONAPI::Document.new("data" => payload)).to_h

      expect { hash["email"] = "changed" }.not_to raise_error
    end

    it "does not overwrite an attribute that happens to be called type" do
      # processor_details really does serialize one, in violation of JSON:API
      # 1.1 §5.2. Merging the resource object's type over it would destroy the
      # value on the one resource where nobody would think to look.
      details = Class.new(described_class) { contract "processor_details" }
      resource = details.new({ "type" => "processor_details",
                               "attributes" => { "type" => "organic" } })

      expect(resource.to_h["type"]).to eq("organic")
      expect(resource.type).to eq("processor_details")
    end
  end

  describe "identity" do
    it "is the record, not the object" do
      # Two distinct objects parsed from two responses describing one customer.
      from_list = CustomerResource.new(payload)
      from_retrieve = CustomerResource.new(payload.dup)

      expect(from_list).to eq(from_retrieve)
      expect(from_list).not_to equal(from_retrieve)
    end

    it "de-duplicates in a Set" do
      expect(Set[CustomerResource.new(payload), CustomerResource.new(payload)].size).to eq(1)
    end

    it "is not shared across classes that report the same type" do
      # RB-3 makes two endpoints report one type. Equality must not merge them.
      other = Class.new(described_class) { contract "merchants" }

      expect(CustomerResource.new(payload)).not_to eq(other.new(payload))
    end

    it "is never equal when there is no id to compare" do
      expect(CustomerResource.new({})).not_to eq(CustomerResource.new({}))
    end

    it "exposes an identifier for the record" do
      expect(resource.identifier)
        .to eq(Edge::JSONAPI::Identifier.new(type: "customers", id: "cus_1"))
    end
  end

  describe "building from a document" do
    it "builds one resource from a single-resource document" do
      document = Edge::JSONAPI::Document.new("data" => payload)
      resource = CustomerResource.from(document)

      expect(resource.email).to eq("ada@example.com")
      expect(resource.document).to be(document)
    end

    it "is nil when the document carried no resource" do
      expect(CustomerResource.from(Edge::JSONAPI::Document.new("data" => nil))).to be_nil
      expect(CustomerResource.from(Edge::JSONAPI::Document.new({}))).to be_nil
    end

    it "builds a list from a collection document" do
      document = Edge::JSONAPI::Document.new("data" => [payload, payload.merge("id" => "cus_2")])

      expect(CustomerResource.list_from(document).map(&:id)).to eq(%w[cus_1 cus_2])
    end

    it "returns an empty list for a single-resource document" do
      # Kernel#Array would have turned the resource hash into its key/value
      # pairs and handed back two nonsense records.
      expect(CustomerResource.list_from(Edge::JSONAPI::Document.new("data" => payload))).to eq([])
    end

    it "skips a malformed element rather than losing the page" do
      document = Edge::JSONAPI::Document.new("data" => [payload, "oops"])

      expect(CustomerResource.list_from(document).map(&:id)).to eq(["cus_1"])
    end
  end

  describe "#inspect" do
    it "prints identity only" do
      # A resource can hold a webhook signing key or a national ID number, and
      # inspect output reaches consoles and every exception reporter.
      expect(resource.inspect).to eq('#<CustomerResource id="cus_1" type="customers">')
      expect(resource.inspect).not_to include("ada@example.com")
    end

    it "keeps a secret out of inspect for a resource that holds one" do
      subscriptions = Class.new(described_class) { contract "webhook_subscriptions" }
      resource = subscriptions.new({ "id" => "whs_1", "type" => "webhook_subscriptions",
                                     "attributes" => { "secret_key" => "whsec_supersecret" } })

      expect(resource.inspect).not_to include("whsec_supersecret")
    end
  end

  describe "a subclass" do
    # The generated readers are inherited, so the metadata describing them must
    # be too. Otherwise a gateway decorating PaymentDemand reports every
    # attribute as drift.
    let(:subclass) { Class.new(CustomerResource) }

    it "keeps the contract binding" do
      expect(subclass.contract_name).to eq("customers")
      expect(subclass.json_api_type).to eq("customers")
    end

    it "keeps the attribute names, so unknown_attributes stays meaningful" do
      expect(subclass.attribute_names).to eq(CustomerResource.attribute_names)
      expect(subclass.new(payload).unknown_attributes).to eq(["loyalty_tier"])
    end

    it "keeps the readers" do
      expect(subclass.new(payload).email).to eq("ada@example.com")
    end

    it "can still be subclassed, since the Ruby hook was not shadowed" do
      expect { Class.new(subclass) }.not_to raise_error
    end
  end

  describe ".for" do
    it "returns the class that declared the contract" do
      expect(described_class.for("customers")).to be(CustomerResource)
    end

    it "resolves to the same registry from a subclass" do
      # `@registry ||= {}` would have given each subclass its own empty hash,
      # so PaymentDemand.for("customers") would quietly answer with the
      # attribute-less base class.
      subclass = Class.new(CustomerResource)

      expect(subclass.for("customers")).to be(CustomerResource)
      expect(subclass.registry).to be(described_class.registry)
    end

    it "generates a class from the manifest when nothing has claimed a name" do
      # Otherwise a relationship would resolve to a bare Edge::Resource with no
      # readers at all, and `demand.payer.fetch.email` — the example in the
      # docs — would raise NoMethodError as shipped.
      described_class.registry.delete("merchants")
      generated = described_class.for("merchants")

      expect(generated).to be < described_class
      expect(generated.contract_name).to eq("merchants")
      expect(generated.new({ "attributes" => { "business_name" => "Acme" } }).business_name)
        .to eq("Acme")
    end

    it "gives a generated class a name, so inspect and backtraces say what it is" do
      described_class.registry.delete("merchants")

      expect(described_class.for("merchants").name)
        .to eq("Edge::Resource::Generated::Merchants")
    end

    it "returns the same generated class every time" do
      # Two lookups held apart, not one expression evaluated twice: generating
      # a fresh class per call would break `is_a?` and `==` for every caller
      # holding one.
      described_class.registry.delete("merchants")
      first = described_class.for("merchants")
      second = described_class.for("merchants")

      expect(first).to be(second)
    end

    it "falls back to the base class for a name the manifest does not have" do
      expect(described_class.for("unicorns")).to be(described_class)
    end
  end

  describe "shadowed relationships" do
    it "are recorded apart from attributes, and stay reachable" do
      # No collision exists in today's manifest, so this builds one. Without
      # it the assertion below compares two empty lists and would pass however
      # the code routed a collision — including into shadowed_attributes,
      # whose documented fallback is `#[]`, which reads attributes and would
      # never find a relationship.
      klass = Class.new(described_class) do
        def merchant = :already_taken
        contract "customers"
      end

      expect(klass.shadowed_relationships).to eq(["merchant"])
      expect(klass.shadowed_attributes).to be_empty
      expect(klass.new({}).merchant).to eq(:already_taken)
      expect(klass.new({}).relationship(:merchant)).to be_a(Edge::Relationship)
    end

    it "are absent from the manifest as it stands" do
      # `#[]` reads attributes. A relationship whose name is taken is reachable
      # only through `#relationship(name)`, so reporting it as a shadowed
      # attribute would send the reader somewhere it will find nothing.
      shadowed = Edge::Contract.resources.keys.to_h do |name|
        [name, Class.new(described_class) { contract(name) }.shadowed_relationships]
      end

      expect(shadowed.reject { |_, names| names.empty? }).to eq({})
    end
  end

  describe "every resource in the manifest" do
    # A generated manifest gains attributes without anyone reading them. An
    # attribute named `hash`, `send` or `class` would take a reader's place and
    # leave a caller reading Object's method instead of their data — silently,
    # and only in production. This is the alarm for that.
    it "shadows only the attributes already known to collide" do
      shadowed = Edge::Contract.resources.keys.to_h do |name|
        [name, Class.new(described_class) { contract(name) }.shadowed_attributes]
      end

      # processor_details serializes an attribute named `type`, which JSON:API
      # 1.1 §5.2 forbids for exactly this reason. It is read as
      # `detail["type"]`; see docs/release-blockers.md, FU-8. Anything else
      # appearing here is a new collision and needs the same treatment.
      expect(shadowed.reject { |_, names| names.empty? })
        .to eq("processor_details" => ["type"])
    end
  end
end
