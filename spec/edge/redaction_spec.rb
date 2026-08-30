# frozen_string_literal: true

RSpec.describe Edge::Redaction do
  describe ".scrub" do
    it "filters an API key while keeping its mode" do
      expect(described_class.scrub("using ept_live_sQsnYGFoLvE2Qt7 now"))
        .to eq("using ept_live_[FILTERED] now")
    end

    it "filters a sandbox key too" do
      expect(described_class.scrub("ept_sandbox_bQsnYGFo")).to eq("ept_sandbox_[FILTERED]")
    end

    it "filters every occurrence" do
      text = "a ept_live_sAAA b ept_sandbox_sBBB c"
      expect(described_class.scrub(text)).to eq("a ept_live_[FILTERED] b ept_sandbox_[FILTERED] c")
    end

    it "filters an Authorization header value" do
      expect(described_class.scrub("Authorization: Bearer abc.def.ghi"))
        .to eq("Authorization: Bearer [FILTERED]")
    end

    it "filters a Basic credential" do
      expect(described_class.scrub("Basic dXNlcjpwYXNz")).to eq("Basic [FILTERED]")
    end

    it "leaves ordinary text alone" do
      expect(described_class.scrub("payment demand succeeded")).to eq("payment demand succeeded")
    end

    it "passes non-strings through" do
      expect(described_class.scrub(nil)).to be_nil
      expect(described_class.scrub(42)).to eq(42)
    end
  end

  describe ".scrub_data" do
    it "filters fields the contract marks sensitive" do
      # These names come from contract/manifest.yml, so the redaction list and
      # the contract cannot drift apart.
      data = { "secret_key" => "whsec_abc", "url" => "https://example.test/hook" }

      expect(described_class.scrub_data(data))
        .to eq("secret_key" => "[FILTERED]", "url" => "https://example.test/hook")
    end

    it "filters KYC identifiers" do
      data = { "id_number" => "123-45-6789", "dob" => "1990-01-01", "nationality" => "US" }

      expect(described_class.scrub_data(data))
        .to eq("id_number" => "[FILTERED]", "dob" => "[FILTERED]", "nationality" => "US")
    end

    it "filters card tokens, which are reusable charge credentials" do
      data = { "card_pan_token" => "tok_abc", "last_four" => "4242" }

      expect(described_class.scrub_data(data))
        .to eq("card_pan_token" => "[FILTERED]", "last_four" => "4242")
    end

    it "filters nested structures" do
      data = { "data" => { "attributes" => { "email" => "a@b.com", "name" => "Ada" } } }

      expect(described_class.scrub_data(data))
        .to eq("data" => { "attributes" => { "email" => "[FILTERED]",
                                             "name" => "[FILTERED]" } })
    end

    it "filters inside arrays" do
      data = { "included" => [{ "token" => "abc" }, { "kind" => "visa" }] }

      expect(described_class.scrub_data(data))
        .to eq("included" => [{ "token" => "[FILTERED]" }, { "kind" => "visa" }])
    end

    it "matches a key given as a JSON Pointer" do
      expect(described_class.scrub_data({ "/data/attributes/id_number" => "123-45-6789" }))
        .to eq("/data/attributes/id_number" => "[FILTERED]")
    end

    it "matches case-insensitively" do
      expect(described_class.scrub_data({ "Secret_Key" => "x" }))
        .to eq("Secret_Key" => "[FILTERED]")
    end

    it "still scrubs keys in values it does not filter wholesale" do
      data = { "description" => "created with ept_live_sAAA" }

      expect(described_class.scrub_data(data))
        .to eq("description" => "created with ept_live_[FILTERED]")
    end
  end

  describe "the contract-derived field list" do
    it "covers the fields the API is known to return" do
      expect(Edge::Contract.all_sensitive_fields)
        .to include("secret_key", "token", "id_number", "dob", "card_pan_token", "line_1")
    end

    it "does not filter ordinary business fields" do
      expect(Edge::Contract.all_sensitive_fields)
        .not_to include("amount_cents", "processor_state", "created_at")
    end
  end
end
