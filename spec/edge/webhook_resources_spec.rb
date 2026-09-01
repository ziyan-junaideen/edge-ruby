# frozen_string_literal: true

RSpec.describe "the refund, event and webhook resources" do
  let(:client) { Edge::Client.new(api_key: "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB") }
  let(:base) { "https://api.tryedge.io" }

  describe Edge::RefundDemand do
    def refund(attributes)
      described_class.new({ "type" => "refund_demands", "id" => "rd_1",
                            "attributes" => attributes })
    end

    let(:created) do
      { "data" => { "type" => "refund_demands", "id" => "rd_1",
                    "attributes" => { "state" => "pending" } } }
    end

    it "maps to the refund_demands contract" do
      expect(described_class.contract_name).to eq("refund_demands")
    end

    describe "states" do
      it "tells errored apart from failed" do
        # A handler checking only `failed?` treats an errored refund as still
        # in progress and waits forever.
        expect(refund("state" => "errored")).to be_errored
        expect(refund("state" => "errored")).not_to be_failed
        expect(refund("state" => "failed")).to be_failed
        expect(refund("state" => "failed")).not_to be_errored
      end

      it "counts errored as settled, and not as in flight" do
        expect(refund("state" => "errored")).to be_settled
        expect(refund("state" => "errored")).not_to be_in_flight
      end

      it "reports the states that are still moving" do
        expect(refund("state" => "pending")).to be_in_flight
        expect(refund("state" => "processing")).to be_in_flight
        expect(refund("state" => "succeeded")).not_to be_in_flight
      end

      it "answers false for a state it has not heard of, and says so" do
        surprising = refund("state" => "clawed_back")

        expect(surprising).not_to be_settled
        expect(surprising).not_to be_in_flight
        expect(surprising).not_to be_state_known
      end

      it "covers exactly the states the contract records" do
        expect(described_class::STATES)
          .to match_array(Edge::Contract.resource("refund_demands")
                            .dig("attributes", "state", "values"))
      end
    end

    describe ".create" do
      # Every refund needs the demand it refunds. The controller destructures
      # the linkage and reads `payment_demand.merchant` off it before any
      # validation runs, so omitting it is a 500 rather than a 422.
      let(:linkage) { { payment_demand: "pd_1" } }

      def create(attributes, **rest)
        described_class.create(attributes, relationships: linkage, client: client, **rest)
      end

      it "needs the payment demand it refunds" do
        expect { described_class.create({ reason: "duplicate_charge" }, client: client) }
          .to raise_error(ArgumentError, /needs the payment demand it refunds/)
      end

      it "needs a reason" do
        expect { create({}) }.to raise_error(ArgumentError, /reason is required/)
        expect { create({ reason: "  " }) }.to raise_error(ArgumentError, /reason is required/)
      end

      it "refuses amount_currency, which the server answers with a 500" do
        # Documented as a string, set with put_change, which does not cast —
        # so the documented "USD" is a 500 and not a validation error. It is
        # inherited from the payment demand and was never the caller's to set.
        expect { create({ reason: "duplicate_charge", amount_currency: "USD" }) }
          .to raise_error(ArgumentError, /inherited from the payment demand/)
      end

      it "refuses attributes the changeset does not cast" do
        # `state` above all: the changeset forces :pending with a `change`
        # before any cast runs, so a caller setting it gets a 201 and no
        # effect.
        expect { create({ reason: "duplicate_charge", state: "succeeded" }) }
          .to raise_error(ArgumentError, /does not accept state/)
      end

      it "refuses a custom reason with nothing written in the note" do
        expect { create({ reason: "custom" }) }
          .to raise_error(ArgumentError, /needs a reason_note/)
        expect { create({ reason: "custom", reason_note: "  " }) }
          .to raise_error(ArgumentError, /needs a reason_note/)
      end

      it "refuses a note longer than the server stores" do
        expect { create({ reason: "custom", reason_note: "x" * 501 }) }
          .to raise_error(ArgumentError, /at most 500/)
      end

      it "accepts a custom reason that carries one" do
        stub_request(:post, "#{base}/v2/refund_demands")
          .to_return(status: 201, body: JSON.generate(created))

        expect(create({ reason: "custom", reason_note: "Goodwill" })).to be_a(described_class)
      end

      it "leaves a non-custom reason's note alone" do
        # The guard must key on the reason, not merely on a note being absent.
        stub_request(:post, "#{base}/v2/refund_demands")
          .to_return(status: 201, body: JSON.generate(created))

        expect { create({ reason: "duplicate_charge" }) }.not_to raise_error
      end

      it "sends the payment demand as linkage inside data" do
        stub_request(:post, "#{base}/v2/refund_demands")
          .to_return(status: 201, body: JSON.generate(created))

        create({ reason: "duplicate_charge" })

        sent = a_request(:post, "#{base}/v2/refund_demands").with do |request|
          JSON.parse(request.body).dig("data", "relationships", "payment_demand", "data") ==
            { "type" => "payment_demands", "id" => "pd_1" }
        end

        expect(sent).to have_been_made
      end

      it "is the one write in this API that may be retried" do
        # And only with a key: the server replays by looking it up, so without
        # one a repeat is a second refund.
        stub_request(:post, "#{base}/v2/refund_demands")
          .to_return(status: 201, body: JSON.generate(created))

        expect { create({ reason: "duplicate_charge", idempotency_key: "k" }, retriable: true) }
          .not_to raise_error
        expect { create({ reason: "duplicate_charge" }, retriable: true) }
          .to raise_error(ArgumentError, /can only be retried with an idempotency_key/)
      end

      it "sends a full refund when no amount is given" do
        stub_request(:post, "#{base}/v2/refund_demands")
          .to_return(status: 201, body: JSON.generate(created))

        create({ reason: "duplicate_charge" })

        sent = a_request(:post, "#{base}/v2/refund_demands").with do |request|
          !JSON.parse(request.body).dig("data", "attributes").key?("amount_cents")
        end

        expect(sent).to have_been_made
      end
    end

    it "reports whether the reason was a custom one" do
      expect(refund("reason" => "custom")).to be_custom_reason
      expect(refund("reason" => "duplicate_charge")).not_to be_custom_reason
    end

    it "offers no refunded-balance arithmetic, because the server tracks none" do
      expect(described_class).not_to respond_to(:remaining, :refundable)
      expect(refund({})).not_to respond_to(:remaining_cents, :refundable_cents)
    end
  end

  describe Edge::Event do
    def event(attributes)
      described_class.new({ "type" => "events", "id" => "evt_1", "attributes" => attributes })
    end

    it "joins the event code the server stores in two columns" do
      # `record_event/3` writes resource_type "transaction.payment_demands"
      # and slug "succeeded"; the joined form exists server-side only as a
      # local used to match subscriptions, and is never stored or delivered.
      subject = event("resource_type" => "transaction.payment_demands", "slug" => "succeeded")

      expect(subject.slug).to eq("succeeded")
      expect(subject.resource_type).to eq("transaction.payment_demands")
      expect(subject.code).to eq("transaction.payment_demands.succeeded")
      expect(subject.domain).to eq("transaction")
    end

    it "has no code when either half is missing" do
      # Rather than "transaction.payment_demands." — a plausible-looking string
      # that matches no subscription and reads fine in a log.
      expect(event("resource_type" => "transaction.payment_demands").code).to be_nil
      expect(event("slug" => "succeeded").code).to be_nil
      expect(event({}).code).to be_nil
      expect(event({}).domain).to be_nil
    end

    it "matches the codes the server's own subscription list documents" do
      # Guards against the split being reintroduced: every code Edge documents
      # must be reachable by joining the two halves an event carries.
      %w[
        transaction.payment_demands.created transaction.payment_demands.succeeded
        transaction.refund_demands.updated consumer.payment_methods.created
      ].each do |code|
        type, _, verb = code.rpartition(".")

        expect(event("resource_type" => type, "slug" => verb).code).to eq(code)
      end
    end

    it "reports the mode the event belongs to" do
      expect(event("mode" => "live")).to be_live
      expect(event("mode" => "live")).not_to be_sandbox
      expect(event("mode" => "sandbox")).to be_sandbox
    end

    it "reads the resource snapshot the event carries" do
      expect(event("data" => { "id" => "pd_1" }).data).to eq("id" => "pd_1")
    end

    it "reports no created_at for a delivered event, which does not carry one" do
      # `event_resource/1` sends mode, resource_type, resource_id, slug and
      # data. A fetched event has created_at; a delivered one does not, and a
      # consumer ordering by it would be ordering by nil.
      expect(event("slug" => "a.b.c").created_at).to be_nil
      expect(event("created_at" => "2026-09-01T00:00:00Z").created_at)
        .to eq("2026-09-01T00:00:00Z")
    end

    it "cannot be created or updated, matching the routes that exist" do
      expect(described_class).not_to respond_to(:create, :update)
      expect(described_class).to respond_to(:list, :retrieve)
    end
  end

  describe Edge::WebhookSubscription do
    def subscription(attributes)
      described_class.new({ "type" => "webhook_subscriptions", "id" => "whs_1",
                            "attributes" => attributes })
    end

    it "reads status and archival separately" do
      expect(subscription("status" => "active")).to be_active
      expect(subscription("status" => "paused")).not_to be_active
      expect(subscription("archived_at" => "2026-09-01T00:00:00Z")).to be_archived
      expect(subscription("archived_at" => nil)).not_to be_archived
    end

    it "reports the event codes it asked for, exactly" do
      subject = subscription("events" => ["transaction.payment_demands.succeeded"])

      expect(subject).to be_subscribed_to("transaction.payment_demands.succeeded")
      # Not a prefix match: a code Edge adds later must not look subscribed.
      expect(subject).not_to be_subscribed_to("transaction.payment_demands.disputed")
      expect(subject).not_to be_subscribed_to("transaction.payment_demands")
    end

    it "reads an event through its code, never its slug" do
      # The bug this pair exists to prevent. `events` holds full codes, an
      # event's `slug` is only the last segment, so comparing the two is false
      # every time — silently, on every delivery.
      subject = subscription("events" => ["transaction.payment_demands.succeeded"])
      delivered = Edge::Event.new(
        { "attributes" => { "resource_type" => "transaction.payment_demands",
                            "slug" => "succeeded" } }
      )

      expect(subject).to be_subscribed_to(delivered)
      expect(subject).not_to be_subscribed_to(delivered.slug)
    end

    it "is not subscribed to an event whose code cannot be built" do
      subject = subscription("events" => ["transaction.payment_demands.succeeded"])

      expect(subject).not_to be_subscribed_to(Edge::Event.new({}))
    end

    it "has an empty event list rather than nil when none were sent" do
      expect(subscription({}).events).to eq([])
    end

    it "keeps the signing key out of inspect while leaving it readable" do
      # It is the key every delivery is signed with. Readable, and redacted
      # everywhere the client prints.
      subject = subscription("secret_key" => "whsec_live_secret", "url" => "https://x.test")

      expect(subject.secret_key).to eq("whsec_live_secret")
      expect(subject.inspect).not_to include("whsec_live_secret")
      expect(Edge::Contract.sensitive_fields("webhook_subscriptions")).to include("secret_key")
    end

    describe ".update" do
      it "refuses a status change, which the API answers 200 and discards" do
        # The controller special-cases status "archived" and otherwise drops
        # status, archived_at and the merchant before the changeset runs. A
        # merchant pausing deliveries got a 200, a subscription still
        # reporting active?, and deliveries still flowing.
        expect { described_class.update("whs_1", { status: "paused" }, client: client) }
          .to raise_error(ArgumentError, /does not accept status/)
      end

      it "refuses secret_key, which is only ever set on create" do
        expect { described_class.update("whs_1", { secret_key: "whsec_mine" }, client: client) }
          .to raise_error(ArgumentError, /does not accept secret_key/)
      end

      it "accepts the attributes the changeset really casts" do
        stub_request(:patch, "#{base}/v2/webhook_subscriptions/whs_1")
          .to_return(status: 200, body: JSON.generate(
            "data" => { "type" => "webhook_subscriptions", "id" => "whs_1" }
          ))

        expect do
          described_class.update("whs_1", { url: "https://example.test/hooks",
                                            events: ["transaction.payment_demands.succeeded"] },
                                 client: client)
        end.not_to raise_error
      end
    end

    describe ".archive" do
      it "is how deliveries are stopped, and sends the one status the API honours" do
        stub_request(:patch, "#{base}/v2/webhook_subscriptions/whs_1")
          .to_return(status: 200, body: JSON.generate(
            "data" => { "type" => "webhook_subscriptions", "id" => "whs_1",
                        "attributes" => { "status" => "archived" } }
          ))

        expect(described_class.archive("whs_1", client: client)).to be_a(described_class)

        sent = a_request(:patch, "#{base}/v2/webhook_subscriptions/whs_1").with do |request|
          JSON.parse(request.body)["data"] ==
            { "type" => "webhook_subscriptions", "attributes" => { "status" => "archived" },
              "id" => "whs_1" }
        end

        expect(sent).to have_been_made
      end

      it "sends no bypass keyword of its own in the body" do
        # It builds the request from the same primitives update does rather
        # than calling update with a flag — a flag would be forwarded into the
        # body and sent as an attribute the server drops without comment.
        stub_request(:patch, "#{base}/v2/webhook_subscriptions/whs_1")
          .to_return(status: 200, body: JSON.generate(
            "data" => { "type" => "webhook_subscriptions", "id" => "whs_1" }
          ))

        described_class.archive("whs_1", client: client)

        sent = a_request(:patch, "#{base}/v2/webhook_subscriptions/whs_1").with do |request|
          JSON.parse(request.body).dig("data", "attributes").keys == ["status"]
        end

        expect(sent).to have_been_made
      end
    end

    it "keeps the signing key out of a response body the client logs" do
      # Structural, by field name, from the same manifest the resource class
      # reads — which is why `sensitive_fields` and the redaction list cannot
      # drift apart.
      body = JSON.generate("data" => { "type" => "webhook_subscriptions",
                                       "attributes" => { "secret_key" => "whsec_live_secret",
                                                         "url" => "https://x.test" } })
      scrubbed = Edge::Redaction.scrub_body(body)

      expect(scrubbed).not_to include("whsec_live_secret")
      expect(scrubbed).to include("https://x.test")
    end
  end

  describe Edge::WebhookDelivery do
    def delivery(attributes)
      described_class.new({ "type" => "webhook_deliveries", "id" => "whd_1",
                            "attributes" => attributes })
    end

    it "reports whether an attempt has failed" do
      expect(delivery("fails_count" => 2)).to be_failed_attempt
      expect(delivery("fails_count" => 0)).not_to be_failed_attempt
      expect(delivery({})).not_to be_failed_attempt
    end

    it "counts the failures, and calls them failures rather than retries" do
      # A 400/401/403/404/405 is never retried, so a delivery your endpoint
      # 404'd has a count of one and was tried exactly once. `retried?` said
      # otherwise.
      expect(delivery("fails_count" => 2).failed_attempts).to eq(2)
      expect(delivery({}).failed_attempts).to eq(0)
      expect(delivery({})).not_to respond_to(:retried?)
    end

    it "is read-only, matching the routes that exist" do
      expect(described_class).not_to respond_to(:create, :update)
    end
  end

  describe "registration" do
    it "resolves each class by its contract name" do
      {
        "refund_demands" => Edge::RefundDemand,
        "events" => Edge::Event,
        "webhook_subscriptions" => Edge::WebhookSubscription,
        "webhook_deliveries" => Edge::WebhookDelivery
      }.each { |name, klass| expect(Edge::Resource.for(name)).to be(klass) }
    end
  end
end
