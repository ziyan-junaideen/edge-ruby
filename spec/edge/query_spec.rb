# frozen_string_literal: true

RSpec.describe Edge::Query do
  # The query string is the contract's most fragile surface: the server drops
  # what it cannot parse instead of rejecting it, so a wrong byte here returns
  # 200 and the wrong records. These assert the exact string sent.
  def encode(**) = described_class.encode(**)

  describe "filters" do
    it "encodes a plain filter" do
      expect(encode(filter: { email: "ada@example.com" }))
        .to eq("filter[email]" => "ada@example.com")
    end

    it "encodes a relationship path with dots, at any depth" do
      expect(encode(filter: { "merchant.account.owner.email" => "ada@example.com" }))
        .to eq("filter[merchant.account.owner.email]" => "ada@example.com")
    end

    it "joins an array into the comma-separated list the server splits on" do
      expect(encode(filter: { processor_state: %w[pending succeeded] }))
        .to eq("filter[processor_state]" => "pending,succeeded")
    end

    it "encodes nil as the null literal the server compiles to IS NULL" do
      expect(encode(filter: { blocked_at: nil })).to eq("filter[blocked_at]" => "null")
    end

    it "encodes times and dates as ISO 8601" do
      expect(encode(filter: {
                      created_at_gte: Time.utc(2026, 8, 30, 12, 0, 0),
                      birth_date_lte: Date.new(2000, 1, 31)
                    })).to eq(
                      "filter[created_at_gte]" => "2026-08-30T12:00:00Z",
                      "filter[birth_date_lte]" => "2000-01-31"
                    )
    end

    it "encodes booleans and integers" do
      expect(encode(filter: { live: true, amount_cents: 500 }))
        .to eq("filter[live]" => "true", "filter[amount_cents]" => "500")
    end
  end

  describe "comparison operators" do
    it "accepts the wire spelling" do
      expect(encode(filter: { "amount_cents_gte" => 1000 }))
        .to eq("filter[amount_cents_gte]" => "1000")
    end

    it "accepts the structured spelling and produces the same query" do
      # Pinned to the literal result as well as to each other: asserting only
      # that the two agree would pass if both returned nothing.
      expect(encode(filter: { amount_cents: { gte: 1000 } }))
        .to eq("filter[amount_cents_gte]" => "1000")
        .and eq(encode(filter: { "amount_cents_gte" => 1000 }))
    end

    it "encodes a range as two parameters" do
      expect(encode(filter: { created_at: { gte: "2026-01-01", lt: "2026-02-01" } })).to eq(
        "filter[created_at_gte]" => "2026-01-01",
        "filter[created_at_lt]" => "2026-02-01"
      )
    end

    it "rejects an operator it does not recognise" do
      expect { encode(filter: { amount_cents: { between: [1, 2] } }) }
        .to raise_error(ArgumentError, /unknown filter operator :between/)
    end

    it "refuses a comparison across a relationship" do
      # parameters.ex:272 only strips the suffix from a single-segment key, so
      # the server would look for a field literally named "amount_cents_gte" on
      # the related record, fail, and drop the filter — returning everything.
      expect { encode(filter: { "payer.amount_cents_gte" => 1000 }) }
        .to raise_error(ArgumentError, /supports only on a resource's own attributes/)
    end

    it "refuses a comparison on id" do
      expect { encode(filter: { "id_gte" => "abc" }) }
        .to raise_error(ArgumentError, /id can only be compared for equality/)
    end

    it "refuses a comparison with several values" do
      expect { encode(filter: { amount_cents: { gte: [1, 2] } }) }
        .to raise_error(ArgumentError, /exactly one non-null value/)
    end

    it "refuses a comparison against null, however it is spelled" do
      # The server trims and then casts both "null" and "NULL" to nil
      # (parameters.ex:615 and :635) before ensure_operator_values rejects it,
      # so all four of these end up as the same dropped filter.
      [nil, "null", "NULL", " null "].each do |value|
        expect { encode(filter: { amount_cents: { gte: value } }) }
          .to raise_error(ArgumentError, /exactly one non-null value/)
      end
    end
  end

  describe "values the server cannot represent" do
    it "refuses a value containing a comma" do
      # There is no escape: parameters.ex:612 splits every string value on ",".
      # "Acme, Inc." would silently become two values OR'd together.
      expect { encode(filter: { name: "Acme, Inc." }) }
        .to raise_error(ArgumentError, /always reads as a value separator/)
    end

    it "refuses a comma inside an array element too" do
      expect { encode(filter: { name: ["Ada", "Acme, Inc."] }) }
        .to raise_error(ArgumentError, /always reads as a value separator/)
    end

    it "refuses an empty filter value" do
      # An empty value empties the value list, which drops the filter, which
      # returns the whole collection — unpaginated, in production.
      expect { encode(filter: { email: "" }) }
        .to raise_error(ArgumentError, /would return the entire collection/)
    end

    it "refuses an all-blank filter value" do
      expect { encode(filter: { email: ["", "  "] }) }
        .to raise_error(ArgumentError, /would return the entire collection/)
    end

    it "refuses a value that is blank only by the server's definition" do
      # Elixir's String.trim removes all Unicode whitespace; Ruby's String#strip
      # removes ASCII only. A non-breaking space — what a browser paste produces
      # — looks like content here and is trimmed to nothing there, dropping the
      # filter and returning everything.
      expect { encode(filter: { email: "\u00A0" }) }
        .to raise_error(ArgumentError, /would return the entire collection/)
    end

    it "refuses a blank value among several, which the server would discard" do
      expect { encode(filter: { email: ["ada@example.com", ""] }) }
        .to raise_error(ArgumentError, /has 1 blank value\(s\) among 2/)
    end

    it "refuses a blank filter name" do
      # `filter[]=x` is parsed by Plug as a list, and the server's filters/1
      # destructures a two-tuple, so it raises rather than ignoring it.
      expect { encode(filter: { "" => "x" }) }
        .to raise_error(ArgumentError, /a filter name is blank/)
      expect { encode(filter: { "  " => "x" }) }
        .to raise_error(ArgumentError, /a filter name is blank/)
    end

    it "refuses an empty array" do
      expect { encode(filter: { email: [] }) }
        .to raise_error(ArgumentError, /would return the entire collection/)
    end

    it "refuses the same filter twice" do
      expect { encode(filter: { "amount_cents_gte" => 1, :amount_cents => { gte: 2 } }) }
        .to raise_error(ArgumentError, /was given twice/)
    end

    it "allows a value that is merely padded, since the server trims it" do
      expect(encode(filter: { name: " Ada " })).to eq("filter[name]" => " Ada ")
    end
  end

  describe "include, sort and sparse fieldsets" do
    it "comma-joins includes" do
      expect(encode(include: %i[payer payment_method]))
        .to eq("include" => "payer,payment_method")
    end

    it "accepts a single include as a scalar" do
      expect(encode(include: :payer)).to eq("include" => "payer")
    end

    it "keeps a nested include path" do
      expect(encode(include: ["payment_demands.payer"]))
        .to eq("include" => "payment_demands.payer")
    end

    it "passes sort direction through as written" do
      expect(encode(sort: ["-created_at", "name"])).to eq("sort" => "-created_at,name")
    end

    it "encodes sparse fieldsets per type" do
      expect(encode(fields: { customers: %i[email name], merchants: ["name"] })).to eq(
        "fields[customers]" => "email,name",
        "fields[merchants]" => "name"
      )
    end

    it "omits an empty list rather than sending a parameter the server ignores" do
      expect(encode(include: [], sort: [], fields: { customers: [] })).to eq({})
    end
  end

  describe "page" do
    it "passes cursor parameters through unchanged" do
      # Deliberately not modelled: the cursor contract is unmerged and
      # production ignores these entirely (docs/pagination.md).
      expect(encode(page: { limit: 50, after: "cursor_abc" })).to eq(
        "page[limit]" => "50",
        "page[after]" => "cursor_abc"
      )
    end
  end

  describe "the raw escape hatch" do
    it "sends params exactly as given" do
      expect(encode(params: { "filter[name]" => "Acme, Inc." }))
        .to eq("filter[name]" => "Acme, Inc.")
    end

    it "wins over a generated parameter" do
      expect(encode(sort: ["name"], params: { "sort" => "-created_at" }))
        .to eq("sort" => "-created_at")
    end
  end

  describe "strict mode" do
    def strict(**) = described_class.encode(resource: "customers", strict: true, **)

    it "allows a known attribute" do
      expect(strict(filter: { email: "ada@example.com" }))
        .to eq("filter[email]" => "ada@example.com")
    end

    it "allows filtering on a belongs-to relationship" do
      expect(strict(filter: { merchant: "abc" })).to eq("filter[merchant]" => "abc")
      expect(strict(filter: { "merchant.id" => "abc" })).to eq("filter[merchant.id]" => "abc")
    end

    it "refuses filtering on a to-many relationship" do
      # relationship_filter/5 requires a BelongsTo association
      # (parameters.ex:417) and drops everything else, so this would return
      # every customer. The manifest records cardinality, so it is catchable.
      expect { strict(filter: { addresses: "adr_1" }) }
        .to raise_error(ArgumentError, /to-many relationship on customers/)
      expect { strict(filter: { "addresses.id" => "adr_1" }) }
        .to raise_error(ArgumentError, /to-many relationship on customers/)
    end

    it "refuses a comparison operator on a relationship" do
      # The suffix is stripped, the relationships branch is taken, and
      # relationship_filter/5 refuses anything but equality (parameters.ex:405).
      expect { strict(filter: { merchant: { gte: "abc" } }) }
        .to raise_error(ArgumentError, /does not have as an attribute/)
    end

    it "refuses id anywhere but as the last segment of a filter" do
      expect { strict(filter: { "id.merchant" => "abc" }) }
        .to raise_error(ArgumentError, /traverses "id"/)
    end

    it "refuses an include of id, which names no relationship" do
      expect { strict(include: %w[id]) }
        .to raise_error(ArgumentError, /traverses "id"/)
    end

    it "allows id, which no resource lists as an attribute" do
      expect(strict(filter: { id: "abc" })).to eq("filter[id]" => "abc")
    end

    it "rejects an unknown attribute and suggests the right one" do
      expect { strict(filter: { emial: "ada@example.com" }) }
        .to raise_error(ArgumentError, /which customers does not have.*Did you mean "email"/m)
    end

    it "follows a relationship chain across resources" do
      expect(strict(filter: { "merchant.business_name" => "Acme" }))
        .to eq("filter[merchant.business_name]" => "Acme")
    end

    it "rejects an unknown field at the far end of a chain" do
      expect { strict(filter: { "merchant.busines_name" => "Acme" }) }
        .to raise_error(ArgumentError, /which merchants does not have/)
    end

    it "rejects traversing something that is not a relationship" do
      expect { strict(filter: { "email.name" => "Acme" }) }
        .to raise_error(ArgumentError, /not a relationship on customers/)
    end

    it "checks the base name of a comparison filter" do
      expect { strict(filter: { crated_at: { gte: "2026-01-01" } }) }
        .to raise_error(ArgumentError, /which customers does not have/)
    end

    it "requires every include segment to be a relationship" do
      expect(strict(include: %w[addresses])).to eq("include" => "addresses")
      expect { strict(include: %w[email]) }
        .to raise_error(ArgumentError, /not a relationship on customers/)
    end

    it "requires a sort to end at an attribute, direction aside" do
      expect(strict(sort: ["-created_at"])).to eq("sort" => "-created_at")
      expect { strict(sort: ["-addresses"]) }
        .to raise_error(ArgumentError, /which customers does not have/)
    end

    it "is off by default, so a manifest gap cannot block a real field" do
      expect(encode(resource: "customers", filter: { brand_new_field: "x" }))
        .to eq("filter[brand_new_field]" => "x")
    end

    it "refuses to be strict with nothing to check against" do
      expect { described_class.new(strict: true) }
        .to raise_error(ArgumentError, /needs a resource:/)
    end

    it "stays quiet when the manifest cannot resolve the resource" do
      expect(described_class.encode(resource: "not_a_resource", strict: true,
                                    filter: { anything: "x" }))
        .to eq("filter[anything]" => "x")
    end
  end

  describe "the whole query" do
    it "builds every parameter together" do
      expect(encode(
               filter: { "payer.email" => "ada@example.com", :amount_cents => { gte: 1000 } },
               include: %i[payer payment_method],
               fields: { customers: %i[email] },
               sort: ["-created_at"],
               page: { limit: 50 }
             )).to eq(
               "filter[payer.email]" => "ada@example.com",
               "filter[amount_cents_gte]" => "1000",
               "include" => "payer,payment_method",
               "fields[customers]" => "email",
               "sort" => "-created_at",
               "page[limit]" => "50"
             )
    end

    it "is empty when nothing was asked for" do
      expect(described_class.new).to be_empty
    end
  end

  describe "on the wire" do
    it "reaches the server as the bracketed form its parser reads" do
      # Faraday percent-encodes the brackets; this asserts the request the
      # server actually receives, not just the hash handed to it.
      stub_request(:get, "https://api.tryedge.io/v2/customers")
        .with(query: { "filter[email]" => "ada@example.com", "sort" => "-created_at" })
        .to_return(status: 200, body: "{}")

      Edge::Client.new(api_key: "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB")
                  .get("v2/customers",
                       params: described_class.encode(filter: { email: "ada@example.com" },
                                                      sort: ["-created_at"]))

      # The stub above would not have matched otherwise, but the point of this
      # example is the bytes, so they are asserted directly.
      sent = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.first
      expect(sent.uri.query).to eq("filter%5Bemail%5D=ada@example.com&sort=-created_at")
    end
  end
end
