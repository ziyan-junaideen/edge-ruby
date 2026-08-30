# frozen_string_literal: true

RSpec.describe Edge::ApiKey do
  # Shapes taken from ept/lib/core/users/merchant_token.ex:127-136, which mints
  # "ept_#{schema}_#{context_first_char}#{Base58.encode(...)}".
  describe ".parse" do
    {
      "ept_live_sQsnYGFoLvE2Qt7tmsvuDESB" => { mode: :live, kind: :secret },
      "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB" => { mode: :sandbox, kind: :secret },
      "ept_live_bQsnYGFoLvE2Qt7tmsvuDESB" => { mode: :live, kind: :browser },
      "ept_sandbox_bQsnYGFoLvE2Qt7tmsvuDESB" => { mode: :sandbox, kind: :browser }
    }.each do |key, expected|
      it "reads #{expected[:mode]}/#{expected[:kind]} from #{key[0, 16]}..." do
        parsed = described_class.parse(key)

        expect(parsed.mode).to eq(expected[:mode])
        expect(parsed.kind).to eq(expected[:kind])
      end
    end

    it "returns nil for a credential of another shape" do
      # OAuth bearer tokens authenticate too. Refusing them, or guessing a mode
      # for them, would both be wrong.
      expect(described_class.parse("some-oauth-bearer-token")).to be_nil
    end

    it "returns nil for a key whose body is not Base58" do
      # 0, O, I and l are excluded from the Base58 alphabet.
      expect(described_class.parse("ept_live_s0OIl")).to be_nil
    end

    it "returns nil for an unknown mode" do
      expect(described_class.parse("ept_staging_sQsnYGFo")).to be_nil
    end

    it "returns nil rather than raising on nil" do
      expect(described_class.parse(nil)).to be_nil
    end

    it "does not match a key with trailing content" do
      expect(described_class.parse("ept_live_sQsnYGFo extra")).to be_nil
    end
  end

  describe "#inspect" do
    it "does not include the key" do
      parsed = described_class.parse("ept_live_sQsnYGFoLvE2Qt7tmsvuDESB")

      expect(parsed.inspect).to eq("#<Edge::ApiKey mode=live kind=secret>")
      expect(parsed.inspect).not_to include("QsnYGFo")
    end
  end
end
