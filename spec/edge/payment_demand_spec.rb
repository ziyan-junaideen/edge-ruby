# frozen_string_literal: true

RSpec.describe Edge::PaymentDemand do
  let(:client) { Edge::Client.new(api_key: "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB") }
  let(:base) { "https://api.tryedge.io" }

  def demand(attributes)
    described_class.new({ "type" => "payment_demands", "id" => "pd_1",
                          "attributes" => attributes }, client: client)
  end

  describe "the two kinds of record this endpoint returns" do
    # `POST /v2/payment_demands` without `confirmed: true` creates a payment
    # intent and renders it through the payment demand view. Both were
    # observed against a running instance; `processor_state` is the only
    # thing that differs.
    it "reads an intent's state as an intent" do
      intent = demand("processor_state" => "incomplete")

      expect(intent).to be_intent
      expect(intent).not_to be_demand
      expect(intent).to be_state_known
    end

    it "reads a charged record's state as a demand" do
      charged = demand("processor_state" => "pending")

      expect(charged).to be_demand
      expect(charged).not_to be_intent
    end

    it "covers every state each kind can hold, with no overlap" do
      # The whole discriminator rests on the two sets being disjoint. If a
      # server ever moved a state from one to the other, `#demand?` would
      # start calling an uncharged record charged.
      expect(described_class::DEMAND_STATES & described_class::INTENT_STATES).to be_empty
      expect(described_class::DEMAND_STATES)
        .to match_array(Edge::Contract.resource("payment_demands")
                          .dig("attributes", "processor_state", "values"))
    end

    it "calls an unknown state neither, rather than guessing" do
      # The safe direction: a state added server-side must not be read as
      # "this was charged".
      unknown = demand("processor_state" => "settling")

      expect(unknown).not_to be_demand
      expect(unknown).not_to be_intent
      expect(unknown).not_to be_state_known
      expect(unknown).not_to be_in_flight
    end

    it "is not confused by a missing state" do
      expect(demand({}).state_known?).to be(false)
    end
  end

  describe "state predicates" do
    {
      "pending" => :pending?, "processing" => :processing?, "succeeded" => :succeeded?,
      "reversed" => :reversed?, "failed" => :failed?, "disputed" => :disputed?,
      "refunded" => :refunded?, "incomplete" => :incomplete?, "ready" => :ready?,
      "canceled" => :canceled?
    }.each do |state, predicate|
      it "answers #{predicate} for #{state} and for nothing else" do
        expect(demand("processor_state" => state).public_send(predicate)).to be(true)
        # Against another real state, not against nil: a predicate wired to
        # the wrong attribute would pass a nil comparison.
        other = state == "pending" ? "succeeded" : "pending"
        expect(demand("processor_state" => other).public_send(predicate)).to be(false)
      end
    end

    it "polls only while the charge is still moving" do
      expect(demand("processor_state" => "pending")).to be_in_flight
      expect(demand("processor_state" => "processing")).to be_in_flight
      expect(demand("processor_state" => "succeeded")).not_to be_in_flight
    end

    it "has no confirmed? predicate, because #confirmed is an attribute" do
      # One character apart and meaning different things — the intent's
      # processor_state versus the boolean the create request carried.
      expect(demand({})).not_to respond_to(:confirmed?)
      expect(demand("confirmed" => true).confirmed).to be(true)
    end

    it "reports a refund without claiming it was a full one" do
      # Any refund of any amount moves the demand here; nothing tracks a
      # refunded total (FU-16).
      expect(demand("processor_state" => "refunded")).to be_refunded
      expect(demand("processor_state" => "refunded")).not_to respond_to(:amount_refunded_cents)
    end
  end

  describe "#verification_passed?" do
    it "is true only when the issuer matched all three checks" do
      expect(demand("cvc2_check" => "match", "address_line1_verification" => "match",
                    "postal_code_verification" => "match")).to be_verification_passed
    end

    it "is false when a check was never run" do
      # The values a record carries before it reaches the processor. Reading
      # "not checked" as "checked and fine" is the whole hazard here.
      expect(demand("cvc2_check" => "unprocessed",
                    "address_line1_verification" => "unverified",
                    "postal_code_verification" => "unverified")).not_to be_verification_passed
    end

    it "is false when only some of them matched" do
      %w[cvc2_check address_line1_verification postal_code_verification].each do |field|
        partial = { "cvc2_check" => "match", "address_line1_verification" => "match",
                    "postal_code_verification" => "match" }.merge(field => "mismatch")

        expect(demand(partial)).not_to be_verification_passed
      end
    end

    it "is false for a record carrying none of them" do
      expect(demand({})).not_to be_verification_passed
    end
  end

  describe "#line_items" do
    it "reads what the server sent" do
      items = [{ "amount_cents" => 500, "quantity" => 1 }]

      expect(demand("line_items" => items).line_items).to eq(items)
    end

    it "is an empty array when there are none" do
      expect(demand({}).line_items).to eq([])
      expect(demand("line_items" => []).line_items).to eq([])
    end
  end

  describe ".create" do
    let(:created) do
      { "data" => { "type" => "payment_demands", "id" => "pd_1",
                    "attributes" => { "processor_state" => "pending" } } }
    end

    it "sends the 3DS results the API requires, which its own views call read-only" do
      # Six attributes carry `readonly: true` in the view and are cast on
      # create anyway; `payer_timezone` is required. Recording them as
      # unwritable made this request impossible to build. See FU-21.
      stub_request(:post, "#{base}/v2/payment_demands")
        .to_return(status: 201, body: JSON.generate(created))

      described_class.create(
        { amount_cents: 500, amount_currency: "USD", eci: "05", threeds_status: "Y",
          threeds_version: "2.2.0", payer_timezone: "Europe/London",
          directory_transaction_eid: "dir_1", acs_transaction_eid: "acs_1" },
        client: client
      )

      sent = a_request(:post, "#{base}/v2/payment_demands").with do |request|
        JSON.parse(request.body).dig("data", "attributes")
            .values_at("eci", "threeds_status", "payer_timezone") ==
          ["05", "Y", "Europe/London"]
      end

      expect(sent).to have_been_made
    end

    it "still refuses the attributes the API really does compute" do
      # `fee_cents` is cast and then overwritten by `cast_fee_cents/2` on
      # create, so sending it cannot change anything; the AVS results are not
      # cast on the create path at all. (`fee_cents` *is* writable on update —
      # `charge_cast_changeset/2` casts it and nothing recomputes it there —
      # and is refused anyway: letting a caller set their own fee is not
      # something to enable on that evidence.)
      %w[fee_cents cvc2_check address_line1_verification postal_code_verification].each do |name|
        expect { described_class.create({ name => "x" }, client: client) }
          .to raise_error(ArgumentError, /set by the API/)
      end
    end

    it "refuses manual capture, which the API accepts and then strands" do
      expect do
        described_class.create({ amount_cents: 5_00, capture_method: "manual" }, client: client)
      end
        .to raise_error(ArgumentError, /no capture and no void route/)
    end

    it "refuses manual capture however the attribute is spelled" do
      # Attributes reach create as a hash or as keywords, with string or
      # symbol keys, and the value may be a symbol too.
      [
        -> { described_class.create(capture_method: "manual", client: client) },
        -> { described_class.create({ "capture_method" => "manual" }, client: client) },
        -> { described_class.create({ capture_method: :manual }, client: client) }
      ].each { |call| expect(&call).to raise_error(ArgumentError, /strands/) }
    end

    it "refuses manual capture when a keyword overrides a benign default" do
      # The bypass this guard had. `write_attributes` merges `**rest` *over*
      # the positional hash, so `create(defaults, capture_method: "manual")` —
      # the ordinary way to layer a per-order override onto shared defaults —
      # sent "manual" while a guard reading the two sources separately found
      # "automatic" and passed. The guard now reads the merged hash.
      stub_request(:post, "#{base}/v2/payment_demands")
        .to_return(status: 201, body: JSON.generate(created))

      expect do
        described_class.create({ "capture_method" => "automatic" },
                               capture_method: "manual", client: client)
      end.to raise_error(ArgumentError, /strands/)

      expect(a_request(:post, "#{base}/v2/payment_demands")).not_to have_been_made
    end

    it "still lets a keyword override a benign default the other way" do
      # The mirror image, so the guard is not simply refusing both hashes.
      stub_request(:post, "#{base}/v2/payment_demands")
        .to_return(status: 201, body: JSON.generate(created))

      expect do
        described_class.create({ "capture_method" => "manual" },
                               capture_method: "automatic", client: client)
      end.not_to raise_error
    end

    it "allows automatic capture, which is what the API does anyway" do
      stub_request(:post, "#{base}/v2/payment_demands")
        .to_return(status: 201, body: JSON.generate(created))

      expect(described_class.create({ capture_method: "automatic" }, client: client))
        .to be_a(described_class)
    end

    it "cannot be marked retriable, because replay does not exist for it" do
      # Both halves refuse it: the contract records no replay guarantee, so
      # Transport rejects the request before it is sent. An idempotency key
      # does not change that — there is nothing server-side to look it up.
      expect { described_class.create({ idempotency_key: "k" }, retriable: true, client: client) }
        .to raise_error(ArgumentError, /no replay contract/)
    end
  end

  describe ".update" do
    let(:updated) do
      { "data" => { "type" => "payment_demands", "id" => "pd_1",
                    "attributes" => { "processor_state" => "failed" } } }
    end

    it "sends the attributes the update changeset casts" do
      # The positive case first: without it every refusal below could be a
      # method that refuses everything.
      stub_request(:patch, "#{base}/v2/payment_demands/pd_1")
        .to_return(status: 200, body: JSON.generate(updated))

      described_class.update("pd_1", { amount_cents: 7_00, purchase_reference: "order-9" },
                             client: client)

      sent = a_request(:patch, "#{base}/v2/payment_demands/pd_1").with do |request|
        JSON.parse(request.body).dig("data", "attributes") ==
          { "amount_cents" => 700, "purchase_reference" => "order-9" }
      end

      expect(sent).to have_been_made
    end

    it "refuses the attributes update accepts and silently discards" do
      # `json_api_update_changeset/2` casts the charge, addendum and settings
      # groups and the relationship ids — not the 3DS results, not
      # capture_method, not idempotency_key. The endpoint answers 200 and
      # changes nothing, which is the failure reject_readonly! exists for and
      # which the resource-level `writable` flag cannot express: it has no
      # per-operation dimension.
      %w[eci threeds_status payer_timezone idempotency_key capture_method].each do |name|
        expect { described_class.update("pd_1", { name => "x" }, client: client) }
          .to raise_error(ArgumentError, /update does not accept #{name}/)
      end
    end

    it "names every attribute it refused, not just the first" do
      expect do
        described_class.update("pd_1", { eci: "05", payer_timezone: "UTC" }, client: client)
      end.to raise_error(ArgumentError, /does not accept eci, payer_timezone/)
    end

    it "does not mistake its own keywords for attributes" do
      stub_request(:patch, "#{base}/v2/payment_demands/pd_1")
        .to_return(status: 200, body: JSON.generate(updated))

      expect { described_class.update("pd_1", { amount_cents: 1 }, client: client) }
        .not_to raise_error
    end

    it "refuses manual capture, which update would discard anyway" do
      # The update-writability message is the accurate one here: update does
      # not set capture_method at all, so nothing would be stranded — the
      # request would simply do nothing.
      expect { described_class.update("pd_1", { capture_method: "manual" }, client: client) }
        .to raise_error(ArgumentError, /does not accept capture_method/)
    end
  end

  describe "#confirm" do
    let(:confirmed) do
      { "data" => { "type" => "payment_demands", "id" => "pd_1",
                    "attributes" => { "processor_state" => "pending" } } }
    end

    it "patches the confirm action and returns the record the server sent" do
      stub_request(:patch, "#{base}/v2/payment_demands/pd_1/confirm")
        .to_return(status: 200, body: JSON.generate(confirmed))

      result = demand("processor_state" => "incomplete").confirm

      expect(result).to be_a(described_class)
      expect(result.processor_state).to eq("pending")
    end

    it "does not change the record it was called on" do
      # `raw` belongs to a frozen document, and a caller still holding the
      # intent must keep seeing the intent.
      stub_request(:patch, "#{base}/v2/payment_demands/pd_1/confirm")
        .to_return(status: 200, body: JSON.generate(confirmed))

      intent = demand("processor_state" => "incomplete")
      intent.confirm

      expect(intent.processor_state).to eq("incomplete")
    end

    it "sends the record's own identity and no attributes" do
      # `do_confirm/2` reads only the include list off the payload, so any
      # attribute sent here would be accepted and dropped without comment.
      stub_request(:patch, "#{base}/v2/payment_demands/pd_1/confirm")
        .to_return(status: 200, body: JSON.generate(confirmed))

      described_class.confirm("pd_1", client: client)

      expect(a_request(:patch, "#{base}/v2/payment_demands/pd_1/confirm")
        .with(body: JSON.generate("data" => { "type" => "payment_demands",
                                              "attributes" => {}, "id" => "pd_1" })))
        .to have_been_made
    end

    it "can never be retried, even if payment demands gained a replay contract" do
      # Confirm on a failed demand is a *retry of the charge*, so replaying it
      # charges again — and that must hold however the resource's own contract
      # changes. Asserting it against today's manifest proves nothing:
      # payment_demands is `idempotent_writes: false`, so Transport refuses
      # the request for a reason that has nothing to do with the path, and the
      # example passes with Request#resource_name reverted.
      #
      # So the flag is stubbed on. What is left is exactly the sub-resource
      # rule: the path resolves to no contract entry.
      allow(Edge::Contract).to receive(:resource).and_call_original
      allow(Edge::Contract).to receive(:resource).with("payment_demands").and_return(
        Edge::Contract.resource("payment_demands").merge("idempotent_writes" => true)
      )

      expect { client.patch("v2/payment_demands/pd_1/confirm", body: "{}", retriable: true) }
        .to raise_error(ArgumentError, /cannot be retried/)
    end

    it "and the collection would be allowed under that same stub" do
      # The control. Without it the example above passes even if the guard
      # refuses every retriable write regardless of path.
      allow(Edge::Contract).to receive(:resource).and_call_original
      allow(Edge::Contract).to receive(:resource).with("payment_demands").and_return(
        Edge::Contract.resource("payment_demands").merge("idempotent_writes" => true)
      )
      stub_request(:post, "#{base}/v2/payment_demands")
        .to_return(status: 201, body: '{"data":{"type":"payment_demands","id":"pd_1"}}')

      expect { client.post("v2/payment_demands", body: "{}", retriable: true) }.not_to raise_error
    end

    it "escapes an id rather than letting it reshape the path" do
      stub_request(:patch, "#{base}/v2/payment_demands/pd%201/confirm")
        .to_return(status: 200, body: JSON.generate(confirmed))

      described_class.confirm("pd 1", client: client)

      expect(a_request(:patch, "#{base}/v2/payment_demands/pd%201/confirm")).to have_been_made
    end

    it "refuses an id that would address the collection" do
      expect { described_class.confirm("..", client: client) }
        .to raise_error(ArgumentError, /is not an id/)
    end

    it "does not reach for the global client when the record has none" do
      # Same rule as Relationship#fetch: a record belonging to one merchant
      # must never be acted on with another's credentials — and this one
      # confirms a charge.
      Edge.configure { |config| config.api_key = "ept_live_sQsnYGFoLvE2Qt7tmsvuDESB" }
      clientless = described_class.new({ "id" => "pd_1", "type" => "payment_demands" })

      expect { clientless.confirm }
        .to raise_error(Edge::ConfigurationError, /must never be acted on with another/)
    ensure
      Edge.reset!
    end
  end

  describe "what the API cannot do, and this class therefore does not offer" do
    it "has no capture and no void" do
      # There is no route for either, and `confirm` is not capture. A method
      # that 404'd would read as a server fault.
      expect(described_class).not_to respond_to(:capture, :void, :cancel, :authorize)
      expect(demand({})).not_to respond_to(:capture, :void, :cancel, :authorize)
    end

    it "has no reader for a field Edge documents and no server sends" do
      # `amount_refunded_cents` is in the OpenAPI snapshot only. A reader
      # returning nil forever reads as "nothing refunded yet".
      expect(described_class.documented_only_attributes).to eq(["amount_refunded_cents"])
      expect(demand({})).not_to respond_to(:amount_refunded_cents)
      expect(described_class.attribute_names).not_to include("amount_refunded_cents")
    end

    it "still lets the value through if a server ever sends one" do
      # Reachable, and reported as drift rather than silently filling a
      # reader nobody has looked at.
      surprising = demand("amount_refunded_cents" => 250)

      expect(surprising[:amount_refunded_cents]).to eq(250)
      expect(surprising.unknown_attributes).to include("amount_refunded_cents")
    end
  end

  describe "registration" do
    it "resolves by contract name, so a relationship finds this class" do
      expect(Edge::Resource.for("payment_demands")).to be(described_class)
    end

    it "keeps money and identity out of inspect" do
      expect(demand("amount_cents" => 500).inspect)
        .to eq('#<Edge::PaymentDemand id="pd_1" type="payment_demands">')
    end
  end
end
