# frozen_string_literal: true

RSpec.describe Edge::JSONAPI::Document do
  let(:single) do
    {
      "data" => {
        "type" => "customers", "id" => "cus_1",
        "attributes" => { "email" => "ada@example.com" },
        "relationships" => {
          "merchant" => { "data" => { "type" => "merchants", "id" => "mer_1" } }
        }
      },
      "included" => [
        { "type" => "merchants", "id" => "mer_1", "attributes" => { "business_name" => "Acme" } }
      ],
      "links" => { "self" => "https://api.tryedge.io/v2/customers/cus_1" },
      "meta" => { "total" => 1 },
      "jsonapi" => { "version" => "1.1" }
    }
  end

  describe "the primary data" do
    it "reads a single resource" do
      document = described_class.new(single)

      expect(document.data["id"]).to eq("cus_1")
      expect(document).not_to be_collection
    end

    it "reads a collection" do
      document = described_class.new("data" => [{ "type" => "customers", "id" => "cus_1" }])

      expect(document).to be_collection
      expect(document.data.length).to eq(1)
    end

    it "distinguishes null data from an absent data member" do
      # `"data": null` is a real answer — a to-one relationship that is unset.
      # A body with no data member at all is a different thing, and conflating
      # them turns "this demand has no payer" into "this response is broken".
      expect(described_class.new("data" => nil)).to be_data
      expect(described_class.new("meta" => {})).not_to be_data
    end

    it "reports an empty document for a body that is not a JSON:API document" do
      # A proxy can return an HTML error page under a 200. Nothing here may
      # raise on it.
      expect(described_class.new("<html>oops</html>")).to be_empty
      expect(described_class.new(nil).data).to be_nil
      expect(described_class.new([1, 2]).included).to eq([])
    end
  end

  describe "members" do
    it "defaults every optional member to an empty collection" do
      document = described_class.new({})

      expect([document.included, document.links, document.meta, document.jsonapi,
              document.errors]).to all(be_empty)
    end

    it "reads the declared members" do
      document = described_class.new(single)

      expect(document.meta).to eq("total" => 1)
      expect(document.jsonapi).to eq("version" => "1.1")
    end
  end

  describe "#link" do
    it "reads a string link" do
      expect(described_class.new(single).link(:self))
        .to eq("https://api.tryedge.io/v2/customers/cus_1")
    end

    it "reads a link object's href" do
      # JSON:API allows either form, and the pagination links this feeds are
      # what the list traversal follows.
      document = described_class.new("links" => { "next" => { "href" => "/v2/customers?page=2" } })

      expect(document.link("next")).to eq("/v2/customers?page=2")
    end

    it "is nil for a missing or unusable link" do
      document = described_class.new("links" => { "next" => 42 })

      expect(document.link("next")).to be_nil
      expect(document.link("prev")).to be_nil
    end
  end

  describe "#find_included" do
    let(:document) { described_class.new(single) }

    it "finds a record by identifier" do
      identifier = Edge::JSONAPI::Identifier.new(type: "merchants", id: "mer_1")

      expect(document.find_included(identifier)["attributes"]).to eq("business_name" => "Acme")
    end

    it "is nil when the server did not send the record" do
      identifier = Edge::JSONAPI::Identifier.new(type: "merchants", id: "mer_2")

      expect(document.find_included(identifier)).to be_nil
      expect(document.find_included(nil)).to be_nil
    end

    it "indexes once rather than scanning per lookup" do
      # A demand with hundreds of included records looked up hundreds of times
      # is quadratic otherwise, and lists are the common case.
      allow(document).to receive(:included).and_call_original

      3.times do
        document.find_included(Edge::JSONAPI::Identifier.new(type: "merchants", id: "mer_1"))
      end

      expect(document).to have_received(:included).once
    end
  end

  describe "a body whose members are the wrong type" do
    # The class promises not to raise on a shape it did not expect, and a guard
    # on the top-level body alone does not deliver that: `{"included": 42}` is
    # a perfectly good Hash.
    let(:nonsense) do
      described_class.new("data" => "?", "included" => 42, "links" => 42, "meta" => 42,
                          "jsonapi" => 42, "errors" => 42)
    end

    it "reports every member as its empty equivalent" do
      expect([nonsense.included, nonsense.links, nonsense.meta, nonsense.jsonapi,
              nonsense.errors]).to all(be_empty)
    end

    it "still inspects" do
      # An exception reporter rendering local variables would otherwise raise
      # while formatting the very document it was trying to describe.
      expect { nonsense.inspect }.not_to raise_error
    end

    it "still looks up an included record" do
      identifier = Edge::JSONAPI::Identifier.new(type: "merchants", id: "mer_1")

      expect(nonsense.find_included(identifier)).to be_nil
    end

    it "still reads a link" do
      expect(nonsense.link("next")).to be_nil
    end
  end

  describe "immutability" do
    it "freezes the body through, so shared records cannot be rewritten" do
      # An included record is aliased by every relationship pointing at it. A
      # caller mutating one resource's view of it would otherwise silently
      # change another's.
      document = described_class.new(single)

      expect { document.data["attributes"]["email"] = "mallory@example.com" }
        .to raise_error(FrozenError)
      expect { document.included.first["id"] = "mer_2" }.to raise_error(FrozenError)
    end

    it "freezes the body it was given, rather than a copy of it" do
      # Deliberate, and worth pinning because it reaches beyond the document:
      # after from_response, the response's parsed body is frozen for every
      # other holder too. Deep-copying each body instead would cost a full
      # traversal on the hot path for a guarantee nobody asked for.
      body = { "data" => { "id" => "cus_1" } }
      described_class.new(body)

      expect(body).to be_frozen
    end
  end

  describe "#inspect" do
    it "names the shape without printing any attribute value" do
      document = described_class.new(single)

      expect(document.inspect).to eq("#<Edge::JSONAPI::Document data=Hash included=1>")
      expect(document.inspect).not_to include("ada@example.com")
    end

    it "reports a collection's length" do
      document = described_class.new("data" => [{ "id" => "1" }, { "id" => "2" }])

      expect(document.inspect).to include("data=[2]")
    end
  end

  describe ".from_response" do
    it "builds from a parsed response body" do
      response = Edge::Response.new(status: 200, headers: {}, body: JSON.generate(single))

      expect(described_class.from_response(response).data["id"]).to eq("cus_1")
    end

    it "builds an empty document from a body that would not parse" do
      response = Edge::Response.new(status: 200, headers: {}, body: "not json")

      expect(described_class.from_response(response)).to be_empty
    end
  end
end
