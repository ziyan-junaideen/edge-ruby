# frozen_string_literal: true

RSpec.describe Edge::JSONAPI::Identifier do
  describe ".from" do
    it "reads a type and id pair" do
      identifier = described_class.from("type" => "customers", "id" => "cus_1")

      expect([identifier.type, identifier.id]).to eq(%w[customers cus_1])
    end

    it "carries meta when the server sent it" do
      identifier = described_class.from("type" => "customers", "id" => "cus_1",
                                        "meta" => { "role" => "payer" })

      expect(identifier.meta).to eq("role" => "payer")
    end

    it "is nil for anything that is not an identifier" do
      expect(described_class.from(nil)).to be_nil
      expect(described_class.from({ "type" => "customers" })).to be_nil
      expect(described_class.from({ "id" => "cus_1" })).to be_nil
      expect(described_class.from("not a hash")).to be_nil
    end

    it "is nil for to-many linkage, which names no single record" do
      # Relationship#resource relies on this: an array of identifiers has no
      # one record to resolve to, and returning the first would be wrong in a
      # way nothing downstream could detect.
      expect(described_class.from([{ "type" => "customers", "id" => "cus_1" }])).to be_nil
    end
  end

  describe "equality" do
    let(:identifier) { described_class.new(type: "customers", id: "cus_1") }

    it "is the type and id pair" do
      expect(identifier).to eq(described_class.new(type: "customers", id: "cus_1"))
    end

    it "ignores meta, so one record described twice de-duplicates" do
      annotated = described_class.new(type: "customers", id: "cus_1", meta: { "role" => "payer" })

      expect(identifier).to eq(annotated)
      expect(Set[identifier, annotated].size).to eq(1)
    end

    it "differs by type and by id" do
      expect(identifier).not_to eq(described_class.new(type: "merchants", id: "cus_1"))
      expect(identifier).not_to eq(described_class.new(type: "customers", id: "cus_2"))
    end

    it "is not equal to a bare hash" do
      expect(identifier).not_to eq("type" => "customers", "id" => "cus_1")
    end

    it "hashes with its equality, so it works as a Hash key" do
      seen = { identifier => :yes }

      expect(seen[described_class.new(type: "customers", id: "cus_1")]).to eq(:yes)
    end
  end

  describe "immutability" do
    it "is frozen, along with the strings it reports" do
      # Freezing the wrapper alone is not enough: String#to_s returns self, so
      # a mutable argument would otherwise be stored by reference.
      identifier = described_class.new(type: +"customers", id: +"cus_1")

      expect(identifier).to be_frozen
      expect([identifier.type, identifier.id, identifier.meta]).to all(be_frozen)
    end

    it "cannot be changed by mutating what it was built from" do
      # An identifier used as a Hash key whose #hash changes underneath it
      # leaves the entry unreachable.
      type = +"customers"
      identifier = described_class.new(type: type, id: "cus_1")
      seen = { identifier => :yes }

      type << "_v2"

      expect(identifier.type).to eq("customers")
      expect(seen[described_class.new(type: "customers", id: "cus_1")]).to eq(:yes)
    end

    it "does not alias the meta hash it was given" do
      meta = { "role" => "payer" }
      identifier = described_class.new(type: "customers", id: "cus_1", meta: meta)

      meta["role"] = "payee"

      expect(identifier.meta).to eq("role" => "payer")
    end
  end

  it "coerces type and id to strings" do
    # An id arriving as an integer must still match one that arrived as a
    # string, or a lookup into `included` silently misses.
    identifier = described_class.new(type: :customers, id: 7)

    expect(identifier).to eq(described_class.new(type: "customers", id: "7"))
  end

  it "prints its identity and nothing else" do
    expect(described_class.new(type: "customers", id: "cus_1").inspect)
      .to eq("#<Edge::JSONAPI::Identifier customers/cus_1>")
  end
end
