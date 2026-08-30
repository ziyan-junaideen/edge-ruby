# frozen_string_literal: true

# The manifest is the contract every resource class will be generated against,
# so its shape is load-bearing. These specs guard the file itself: that it
# parses, that the invariants the client relies on hold, and that the known
# server bugs it records have not silently changed shape.
RSpec.describe "contract/manifest.yml" do
  subject(:manifest) { YAML.load_file(File.expand_path("../../contract/manifest.yml", __dir__)) }

  let(:resources) { manifest.fetch("resources") }

  it "carries every resource the client routes" do
    # Exact, not a floor: a new resource on the Edge side should surface here
    # as a failing example that prompts a review, not pass unnoticed.
    expect(resources.size).to eq(30)
  end

  it "keeps its caveats with it" do
    expect(manifest["caveats"]).to be_an(Array).and(be_any { |c| c.include?("requestBody: null") })
  end

  describe "every resource" do
    it "declares an api_version the client can route" do
      versions = resources.transform_values { |spec| spec["api_version"] }
      expect(versions.values.uniq).to contain_exactly("v1", "v2")
    end

    it "declares at least one operation" do
      empty = resources.reject { |_, spec| spec["operations"].any? }
      expect(empty.keys).to be_empty
    end

    it "declares only operations the client knows how to build" do
      known = %w[list retrieve create update delete]
      unknown = resources.flat_map { |_, spec| spec["operations"] } - known
      expect(unknown).to be_empty
    end

    it "names a JSON:API type" do
      # `include` on a Hash only tests for the key, so a null value would pass.
      missing = resources.reject { |_, spec| spec["json_api_type"].is_a?(String) }
      expect(missing.keys).to be_empty
    end

    it "points every relationship at a known view" do
      views = resources.values.map { |spec| spec["json_api_type"] }
      # Views are named in CamelCase; compare on a normalized form.
      known = views.to_set { |type| type.split("_").map(&:capitalize).join }

      dangling = resources.flat_map do |name, spec|
        spec["relationships"].filter_map do |rel, target|
          "#{name}.#{rel} -> #{target["view"]}" unless known.include?(target["view"])
        end
      end
      expect(dangling).to be_empty
    end

    it "marks each relationship's cardinality" do
      cardinalities = resources.flat_map { |_, spec| spec["relationships"].values }
                               .map { |target| target["cardinality"] }
      expect(cardinalities.uniq).to match_array(%w[one many])
    end
  end

  describe "redaction obligations" do
    # If a field named here stops being redacted, secrets reach logs. These are
    # the specific fields the API returns that must never be printed.
    {
      "merchant_tokens" => "token",
      "webhook_subscriptions" => "secret_key",
      "payment_methods" => "card_pan_token",
      "personal_identifications" => "id_number",
      "consumer_addresses" => "line_1"
    }.each do |resource, field|
      it "marks #{resource}.#{field} sensitive" do
        expect(resources.fetch(resource)["sensitive_fields"]).to include(field)
      end
    end

    it "lists nothing a resource does not declare" do
      phantom = resources.flat_map do |name, spec|
        (spec["sensitive_fields"] - spec["attributes"].keys).map { |f| "#{name}.#{f}" }
      end
      expect(phantom).to be_empty
    end
  end

  describe "write safety" do
    it "marks only the resource whose replay contract has been exercised" do
      # refund_demands is the only one proven: one key, two POSTs, one record
      # (docs/release-blockers.md, FU-20). payment_demands *documents* a replay
      # contract — its view calls idempotency_key "a unique value that prevents
      # double charging" — and does not have one, so it is excluded on the
      # evidence rather than on the documentation. Exact, not a floor: adding a
      # resource here must be a deliberate act backed by a sandbox run.
      idempotent = resources.select { |_, spec| spec["idempotent_writes"] }.keys
      expect(idempotent).to contain_exactly("refund_demands")
    end

    it "does not claim idempotency for a resource that cannot be created" do
      idempotent = resources.select { |_, spec| spec["idempotent_writes"] }
      expect(idempotent).not_to be_empty

      uncreatable = idempotent.reject { |_, spec| spec["operations"].include?("create") }
      expect(uncreatable.keys).to be_empty
    end
  end

  describe "recorded server bugs" do
    # These assertions fail when Edge fixes the bug, which is the point: the
    # client's workaround becomes removable and docs/release-blockers.md stale.
    it "still reports financial_institutions under the beneficial_owners type (RB-3)" do
      expect(resources.dig("financial_institutions", "json_api_type")).to eq("beneficial_owners")
    end

    it "still has no amount_refunded_cents outside the snapshot (RB-2)" do
      # dig throughout: if Edge drops the field entirely this should fail with
      # a readable diff, not a NoMethodError on nil.
      expect(resources.dig("payment_demands", "attributes", "amount_refunded_cents", "from"))
        .to eq("openapi-snapshot-only")
    end

    it "records the two confirm actions and no capture or void route (RB-1)" do
      actions = resources.flat_map do |name, spec|
        spec["custom_actions"].map { |action| "#{name}#{action["path"]}" }
      end
      expect(actions).to contain_exactly(
        "payment_demands/{id}/confirm",
        "payment_subscriptions/{id}/confirm"
      )
    end
  end

  describe "enum values" do
    it "carries the custom refund reason the snapshot predates" do
      reason = resources.dig("refund_demands", "attributes", "reason")
      expect(reason["values"]).to include("custom")
      expect(reason["snapshot_stale"]).to be(true)
    end

    it "takes exactly these value sets from the snapshot and no others" do
      # Pinned rather than merely reported. The client must tolerate unknown
      # enum values regardless, but a value set silently starting to come from
      # the untrusted snapshot is a change worth seeing.
      from_snapshot = resources.flat_map do |name, spec|
        spec["attributes"].filter_map do |field, attr|
          "#{name}.#{field}" if attr["values_from"] == "openapi-snapshot"
        end
      end
      expect(from_snapshot).to contain_exactly(
        "payment_methods.kind",
        "payment_subscriptions.billing_period",
        "red_flags.violation"
      )
    end
  end
end
