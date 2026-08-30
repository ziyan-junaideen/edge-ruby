# frozen_string_literal: true

RSpec.describe Edge::Operations do
  let(:secret) { "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB" }
  let(:client) { Edge::Client.new(api_key: secret) }
  let(:retrying_client) do
    Edge::Client.new(
      api_key: secret,
      retry_policy: Edge::RetryPolicy.new(max_retries: 2, base_delay: 0, max_delay: 0,
                                          sleeper: ->(_) {})
    )
  end
  let(:base) { "https://api.tryedge.io" }

  def customer_body(id = "cus_1", attributes = { "email" => "ada@example.com" })
    JSON.generate("data" => { "type" => "customers", "id" => id, "attributes" => attributes })
  end

  describe "only the operations the endpoint has" do
    it "gives a payment method no way to be created, updated or deleted" do
      # /v2/payment_methods is mounted only: [:index, :show]
      # (core_web/router.ex:270-274). A `.create` that existed and returned 404
      # would read as a server fault rather than as a capability the API does
      # not have — and card data is meant to reach the vault from the browser,
      # never from a merchant's server.
      expect(Edge::PaymentMethod).not_to respond_to(:create)
      expect(Edge::PaymentMethod).not_to respond_to(:update)
      expect(Edge::PaymentMethod).not_to respond_to(:delete)
      expect { Edge::PaymentMethod.create({}) }.to raise_error(NoMethodError, /create/)
    end

    it "still lets a payment method be read" do
      expect(Edge::PaymentMethod).to respond_to(:list, :retrieve)
    end

    it "gives a customer the four operations the manifest records" do
      expect(Edge::Customer).to respond_to(:create, :list, :retrieve, :update)
    end

    it "matches the manifest for every resource that declares operations" do
      # The pairing that matters: a method exists exactly when the contract
      # says the route does.
      { Edge::Customer => "customers", Edge::ConsumerAddress => "consumer_addresses",
        Edge::PaymentMethod => "payment_methods" }.each do |klass, name|
        declared = Edge::Contract.resource(name)["operations"]
        supported = Edge::Operations::MODULES.keys.select { |op| klass.respond_to?(op) }

        expect(supported).to match_array(declared)
      end
    end

    it "refuses to declare a resource whose operations it cannot build" do
      allow(Edge::Contract).to receive(:resource)
        .with("customers")
        .and_return("api_version" => "v2", "operations" => %w[teleport])

      expect { Class.new(Edge::Resource) { contract "customers" } }
        .to raise_error(Edge::Error, /does not know how to build/)
    end
  end

  describe ".retrieve" do
    it "gets one record by id" do
      stub_request(:get, "#{base}/v2/customers/cus_1").to_return(status: 200, body: customer_body)

      customer = Edge::Customer.retrieve("cus_1", client: client)

      expect(customer).to be_a(Edge::Customer)
      expect(customer.email).to eq("ada@example.com")
      expect(customer.client).to be(client)
    end

    it "passes query parameters through Edge::Query" do
      stub_request(:get, "#{base}/v2/customers/cus_1")
        .with(query: { "include" => "addresses", "fields[customers]" => "email" })
        .to_return(status: 200, body: customer_body)

      Edge::Customer.retrieve("cus_1", client: client, include: %i[addresses],
                                       fields: { customers: %i[email] })

      expect(a_request(:get, "#{base}/v2/customers/cus_1")
        .with(query: { "include" => "addresses", "fields[customers]" => "email" }))
        .to have_been_made
    end

    it "escapes an id rather than letting it rewrite the path" do
      # An id is caller input. One containing a slash would otherwise address a
      # different resource entirely.
      stub_request(:get, "#{base}/v2/customers/..%2Fmerchants").to_return(status: 200, body: "{}")

      Edge::Customer.retrieve("../merchants", client: client)

      expect(a_request(:get, "#{base}/v2/customers/..%2Fmerchants")).to have_been_made
    end

    it "escapes a space as %20, not as +" do
      # `encode_www_form_component` writes `+`, which a path does not decode.
      # The server would read the id as "a+b" from the URL and "a b" from the
      # body, and id_required_plug would answer 400 for a mismatch nobody
      # could see.
      stub_request(:get, "#{base}/v2/customers/a%20b").to_return(status: 200, body: "{}")

      Edge::Customer.retrieve("a b", client: client)

      expect(a_request(:get, "#{base}/v2/customers/a%20b")).to have_been_made
    end

    it "refuses a dot segment, which would resolve away to the collection" do
      # `.` and `..` are unreserved, so escaping leaves them and URI resolution
      # removes them: `retrieve(".")` would GET every customer — unpaginated —
      # and hand back nil, with no error anywhere.
      [".", ".."].each do |dots|
        expect { Edge::Customer.retrieve(dots, client: client) }
          .to raise_error(ArgumentError, /is not an id/)
      end
    end

    it "refuses an id that is blank only by Unicode's reckoning" do
      expect { Edge::Customer.retrieve("\u00A0", client: client) }
        .to raise_error(ArgumentError, /id is required/)
    end

    it "refuses an empty id rather than listing the collection" do
      # `retrieve(nil)` hitting /v2/customers would return every customer under
      # a method whose whole promise is one record.
      [nil, "", "  "].each do |bad|
        expect { Edge::Customer.retrieve(bad, client: client) }
          .to raise_error(ArgumentError, /id is required/)
      end
    end
  end

  describe ".list" do
    it "returns a list object built with the right class and client" do
      stub_request(:get, "#{base}/v2/customers").to_return(
        status: 200,
        body: JSON.generate("data" => [{ "type" => "customers", "id" => "cus_1" }])
      )

      customers = Edge::Customer.list(client: client)

      expect(customers).to be_a(Edge::ListObject)
      expect(customers.first).to be_a(Edge::Customer)
      expect(customers.first.client).to be(client)
    end

    it "encodes filters the way the server's parser reads them" do
      stub_request(:get, "#{base}/v2/customers")
        .with(query: { "filter[email]" => "ada@example.com", "sort" => "-created_at" })
        .to_return(status: 200, body: '{"data":[]}')

      Edge::Customer.list(client: client, filter: { email: "ada@example.com" },
                          sort: ["-created_at"])

      expect(a_request(:get, "#{base}/v2/customers")
        .with(query: { "filter[email]" => "ada@example.com", "sort" => "-created_at" }))
        .to have_been_made
    end

    it "checks names against the contract when the client asks it to" do
      strict = Edge::Client.new(api_key: secret, strict: true)

      expect { Edge::Customer.list(client: strict, filter: { emial: "x" }) }
        .to raise_error(ArgumentError, /which customers does not have/)
    end

    it "cannot have its name checking redirected by a caller's keyword" do
      # `resource:` and `strict:` are applied after the caller's keywords, so
      # neither can be displaced. Splatted first, `list(resource: "merchants")`
      # would check customer filters against the merchants contract, and
      # `strict: false` would switch the checking off entirely.
      strict = Edge::Client.new(api_key: secret, strict: true)

      expect { Edge::Customer.list(client: strict, resource: "merchants", filter: { emial: "x" }) }
        .to raise_error(ArgumentError, /which customers does not have/)
      expect { Edge::Customer.list(client: strict, strict: false, filter: { emial: "x" }) }
        .to raise_error(ArgumentError, /which customers does not have/)
    end

    it "does not check them by default, so a manifest gap cannot block a field" do
      stub_request(:get, "#{base}/v2/customers").with(query: { "filter[brand_new]" => "x" })
                                                .to_return(status: 200, body: '{"data":[]}')

      expect { Edge::Customer.list(client: client, filter: { brand_new: "x" }) }
        .not_to raise_error
    end
  end

  describe ".create" do
    it "sends a JSON:API document with the type the server matches on" do
      stub_request(:post, "#{base}/v2/customers").to_return(status: 201, body: customer_body)

      Edge::Customer.create({ email: "ada@example.com", name: "Ada" }, client: client)

      expect(a_request(:post, "#{base}/v2/customers").with(
               body: { "data" => { "type" => "customers",
                                   "attributes" => { "email" => "ada@example.com",
                                                     "name" => "Ada" } } }
             )).to have_been_made
    end

    it "sends the JSON:API type, not the route name, when they differ" do
      # They do differ: /v2/financial_institutions reports the type
      # "beneficial_owners" (docs/release-blockers.md, RB-3). That endpoint is
      # read-only, so the divergence is reproduced here rather than borrowed —
      # without it, every resource this client writes to has the two the same
      # and nothing would notice the wrong one being used.
      allow(Edge::Contract).to receive(:resource).and_call_original
      allow(Edge::Contract).to receive(:resource).with("widgets").and_return(
        "api_version" => "v2", "json_api_type" => "sprockets",
        "operations" => %w[create], "attributes" => {}, "relationships" => {}
      )
      klass = Class.new(Edge::Resource) { contract "widgets" }
      stub_request(:post, "#{base}/v2/widgets").to_return(status: 201, body: "{}")

      klass.create({ size: 1 }, client: client)

      expect(a_request(:post, "#{base}/v2/widgets").with do |request|
        JSON.parse(request.body).dig("data", "type") == "sprockets"
      end).to have_been_made
    end

    it "accepts attributes as keywords too" do
      stub_request(:post, "#{base}/v2/customers").to_return(status: 201, body: customer_body)

      Edge::Customer.create(email: "ada@example.com", client: client)

      expect(a_request(:post, "#{base}/v2/customers").with(
               body: { "data" => { "type" => "customers",
                                   "attributes" => { "email" => "ada@example.com" } } }
             )).to have_been_made
    end

    it "builds linkage from a resource, an identifier, or a bare id" do
      # The ids differ per call, so the branches are distinguishable. Asserting
      # only the type would pass with every branch hard-coded to one record.
      stub_request(:post, "#{base}/v2/consumer_addresses")
        .to_return(status: 201, body: '{"data":{"type":"consumer_addresses","id":"adr_1"}}')

      {
        "cus_1" => Edge::Customer.new({ "type" => "customers", "id" => "cus_1" }),
        "cus_2" => Edge::JSONAPI::Identifier.new(type: "customers", id: "cus_2"),
        "cus_3" => "cus_3"
      }.each do |id, value|
        Edge::ConsumerAddress.create({}, client: client, relationships: { customer: value })

        sent = a_request(:post, "#{base}/v2/consumer_addresses").with do |request|
          JSON.parse(request.body).dig("data", "relationships", "customer", "data") ==
            { "type" => "customers", "id" => id }
        end

        expect(sent).to have_been_made
      end
    end

    it "accepts a ready-made linkage hash under either key spelling" do
      stub_request(:post, "#{base}/v2/consumer_addresses")
        .to_return(status: 201, body: '{"data":{"type":"consumer_addresses","id":"adr_1"}}')
      linkage = { data: { type: "customers", id: "cus_1" } }

      Edge::ConsumerAddress.create({}, client: client, relationships: { customer: linkage })

      sent = a_request(:post, "#{base}/v2/consumer_addresses").with do |request|
        JSON.parse(request.body).dig("data", "relationships", "customer", "data") ==
          { "type" => "customers", "id" => "cus_1" }
      end

      expect(sent).to have_been_made
    end

    it "builds to-many linkage as the array JSON:API specifies" do
      stub_request(:post, "#{base}/v2/customers").to_return(status: 201, body: customer_body)

      Edge::Customer.create({ name: "Ada" }, client: client,
                                             relationships: { addresses: %w[adr_1 adr_2] })

      sent = a_request(:post, "#{base}/v2/customers").with do |request|
        JSON.parse(request.body).dig("data", "relationships", "addresses", "data") ==
          [{ "type" => "consumer_addresses", "id" => "adr_1" },
           { "type" => "consumer_addresses", "id" => "adr_2" }]
      end

      expect(sent).to have_been_made
    end

    it "resolves the related type through the view name, not the relationship name" do
      # `consumer_addresses.customer` points at the view `Customers`. A naive
      # `view.downcase` gives "customers" here by luck; the relationship named
      # `addresses` points at `ConsumerAddresses`, where it would give
      # "consumeraddresses" and resolve to nothing.
      stub_request(:post, "#{base}/v2/customers").to_return(status: 201, body: customer_body)

      Edge::Customer.create({ name: "Ada" }, client: client,
                                             relationships: { addresses: %w[adr_1] })

      sent = a_request(:post, "#{base}/v2/customers").with do |request|
        JSON.parse(request.body).dig("data", "relationships", "addresses", "data", 0, "type") ==
          "consumer_addresses"
      end

      expect(sent).to have_been_made
    end

    it "refuses to unset a relationship, which the API answers with a 500" do
      # phoenix_jsonapi/conn.ex:256 carries the comment
      # "TODO: Handle %{"data" => null}" and has no clause for it.
      expect { Edge::ConsumerAddress.create({}, client: client, relationships: { customer: nil }) }
        .to raise_error(ArgumentError, /cannot be unset/)
    end

    it "refuses a record with no type to link to, rather than sending null" do
      # Identifier.from needs both type and id. Without this the linkage
      # degrades to {"data": null} — an unset, which is not what was asked for
      # and which the API cannot process either.
      typeless = Edge::Customer.new({ "id" => "cus_1" })

      expect do
        Edge::ConsumerAddress.create({}, client: client,
                                         relationships: { customer: typeless })
      end
        .to raise_error(ArgumentError, /has no type and id/)
    end

    it "refuses a relationship the API sets itself" do
      # `merchant` is writable: false. The server recognises the name, so it
      # gets past validation and into a controller with no clause for it — a
      # 500 rather than a 422.
      expect do
        Edge::ConsumerAddress.create({}, client: client,
                                         relationships: { merchant: "mer_1" })
      end
        .to raise_error(ArgumentError, /is set by the API/)
    end

    it "refuses an array for a to-one and a single value where the shape is wrong" do
      expect do
        Edge::ConsumerAddress.create({}, client: client,
                                         relationships: { customer: %w[cus_1 cus_2] })
      end
        .to raise_error(ArgumentError, /holds one record, not a list/)
    end

    it "puts relationships inside data, where the server reads them" do
      # phoenix_jsonapi/conn.ex:136 matches on
      # `params: %{"data" => %{"relationships" => ...}}`. A sibling of `data`
      # would be ignored and the address would be created unattached.
      stub_request(:post, "#{base}/v2/consumer_addresses")
        .to_return(status: 201, body: '{"data":{"type":"consumer_addresses","id":"adr_1"}}')

      Edge::ConsumerAddress.create({}, client: client, relationships: { customer: "cus_1" })

      nested = a_request(:post, "#{base}/v2/consumer_addresses").with do |request|
        body = JSON.parse(request.body)
        body.dig("data", "relationships").is_a?(Hash) && !body.key?("relationships")
      end

      expect(nested).to have_been_made
    end

    it "refuses a relationship the resource does not have, whatever the value" do
      # The check has to come before the value dispatch. Doing it only on the
      # bare-id branch let a resource, an identifier and a ready-made hash all
      # past the one guard there was.
      [
        "cus_1",
        Edge::Customer.new({ "type" => "customers", "id" => "cus_1" }),
        Edge::JSONAPI::Identifier.new(type: "customers", id: "cus_1"),
        { "data" => { "type" => "customers", "id" => "cus_1" } }
      ].each do |value|
        expect do
          Edge::ConsumerAddress.create({}, client: client,
                                           relationships: { payer: value })
        end
          .to raise_error(ArgumentError, /no relationship called "payer"/)
      end
    end

    it "is not retriable, because a repeat would create a second record" do
      stub_request(:post, "#{base}/v2/customers")
        .to_return({ status: 500, body: "boom" }, { status: 201, body: customer_body })
      retrying = Edge::Client.new(
        api_key: secret,
        retry_policy: Edge::RetryPolicy.new(max_retries: 2, base_delay: 0, max_delay: 0,
                                            sleeper: ->(_) {})
      )

      expect { Edge::Customer.create({ email: "ada@example.com" }, client: retrying) }
        .to raise_error(Edge::ServerError)
      expect(a_request(:post, "#{base}/v2/customers")).to have_been_made.once
    end

    describe "retriable: true" do
      # Proven against a live instance: posting the same refund twice with one
      # idempotency_key returned the same record id both times, the second
      # carrying the state it had reached since. Without a key the server's
      # replay lookup falls through (core/transactions.ex:898) and inserts a
      # second refund, so both halves are checked before a write may repeat.
      let(:refund) { Class.new(Edge::Resource) { contract "refund_demands" } }

      it "repeats a write the contract records a replay contract for" do
        stub_request(:post, "#{base}/v2/refund_demands")
          .to_return({ status: 500, body: "boom" },
                     { status: 201, body: JSON.generate(
                       "data" => { "type" => "refund_demands", "id" => "ref_1" }
                     ) })

        record = refund.create({ amount_cents: 100, idempotency_key: "key-1" },
                               client: retrying_client, retriable: true)

        expect(record.id).to eq("ref_1")
        expect(a_request(:post, "#{base}/v2/refund_demands")).to have_been_made.twice
      end

      it "refuses without an idempotency_key, which is what makes it a replay" do
        # No stub: the request must not be sent at all. One that were sent
        # would fail the example on WebMock's unstubbed-request error, which
        # is the assertion here.
        expect { refund.create({ amount_cents: 100 }, client: client, retriable: true) }
          .to raise_error(ArgumentError, /only be retried with an idempotency_key/)
      end

      it "refuses a blank key as firmly as a missing one" do
        expect do
          refund.create({ amount_cents: 100, idempotency_key: "  " },
                        client: client, retriable: true)
        end.to raise_error(ArgumentError, /only be retried with an idempotency_key/)
      end

      it "refuses on update, where the API has no replay lookup at all" do
        # `idempotent_writes` is recorded per resource and payment_demands has
        # it, so a gate that consulted only the contract would allow this.
        demand = Class.new(Edge::Resource) { contract "payment_demands" }

        expect { demand.update("pd_1", { description: "x" }, client: client, retriable: true) }
          .to raise_error(ArgumentError, /Nothing replays a PATCH/)
      end

      it "refuses a payment demand, whose replay contract does not exist" do
        # The one finding in this area that would have moved money twice. The
        # view documents idempotency_key as "a unique value that prevents
        # double charging"; against a running instance the key is dropped on
        # create and two identical POSTs produced two demands, both 201
        # (docs/release-blockers.md, FU-20). Supplying a key must not make this
        # look safe.
        demand = Class.new(Edge::Resource) { contract "payment_demands" }

        expect do
          demand.create({ amount_cents: 1, idempotency_key: "key-1" },
                        client: client, retriable: true)
        end.to raise_error(ArgumentError, /cannot be retried/)
      end

      it "names the missing replay contract, not the missing key" do
        # customers has no replay contract, so asking the caller for an
        # idempotency key would send them to add one that changes nothing.
        expect do
          Edge::Customer.create({ email: "ada@example.com" }, client: client, retriable: true)
        end.to raise_error(ArgumentError, /cannot be retried/)
      end

      it "still refuses a resource the contract records no replay contract for" do
        # customers has no idempotency_key at all, so a key cannot make it
        # safe. The contract is checked as well as the key.
        expect do
          Edge::Customer.create({ email: "ada@example.com", idempotency_key: "key-1" },
                                client: client, retriable: true)
        end.to raise_error(ArgumentError, /cannot be retried/)
      end
    end
  end

  describe "attribute names" do
    it "refuses an attribute the API sets itself" do
      # payment_demands.fee_cents is writable: false — it would be dropped from
      # the request without comment. Refused before anything is sent, so no
      # stub is needed and none is registered: a request here would fail.
      demand = Class.new(Edge::Resource) { contract "payment_demands" }

      expect { demand.create({ fee_cents: 1 }, client: client) }
        .to raise_error(ArgumentError, /is set by the API/)
    end

    it "refuses a misspelled attribute in strict mode and suggests the right one" do
      # The server drops an attribute its view does not declare
      # (phoenix_jsonapi/view.ex:107), so a typo returns 200 and changes
      # nothing at all.
      strict = Edge::Client.new(api_key: secret, strict: true)

      expect { Edge::Customer.update("cus_1", { emial: "x@example.com" }, client: strict) }
        .to raise_error(ArgumentError, /no attribute called "emial".*Did you mean "email"/m)
    end

    it "lets an unknown attribute through by default, so a manifest gap cannot block one" do
      stub_request(:post, "#{base}/v2/customers").to_return(status: 201, body: customer_body)

      expect { Edge::Customer.create({ brand_new: "x" }, client: client) }.not_to raise_error
    end
  end

  describe ".update" do
    it "patches the member path and carries the id in the body" do
      stub_request(:patch, "#{base}/v2/customers/cus_1")
        .to_return(status: 200, body: customer_body)

      Edge::Customer.update("cus_1", { email: "new@example.com" }, client: client)

      expect(a_request(:patch, "#{base}/v2/customers/cus_1").with(
               body: { "data" => { "type" => "customers", "id" => "cus_1",
                                   "attributes" => { "email" => "new@example.com" } } }
             )).to have_been_made
    end
  end

  describe "the default client" do
    it "is used when none is passed" do
      Edge.configure { |config| config.api_key = secret }
      stub_request(:get, "#{base}/v2/customers/cus_1").to_return(status: 200, body: customer_body)

      expect(Edge::Customer.retrieve("cus_1").email).to eq("ada@example.com")
    ensure
      Edge.reset!
    end

    it "raises rather than sending an unauthenticated request when there is none" do
      expect { Edge::Customer.retrieve("cus_1") }
        .to raise_error(Edge::ConfigurationError, /not configured/)
    end
  end
end
