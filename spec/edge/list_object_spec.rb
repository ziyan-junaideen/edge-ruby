# frozen_string_literal: true

RSpec.describe Edge::ListObject do
  before { stub_const("CustomerResource", Class.new(Edge::Resource) { contract "customers" }) }

  let(:client) { Edge::Client.new(api_key: "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB") }
  let(:base) { "https://api.tryedge.io" }

  def page(ids, links = {})
    Edge::JSONAPI::Document.new(
      "data" => ids.map { |id| { "type" => "customers", "id" => id } },
      "links" => links,
      "meta" => { "total" => ids.length }
    )
  end

  def list(document)
    described_class.new(document: document, client: client, resource_class: CustomerResource)
  end

  describe "one page" do
    subject(:records) { list(page(%w[cus_1 cus_2])) }

    it "enumerates its own records" do
      expect(records.map(&:id)).to eq(%w[cus_1 cus_2])
      expect(records.length).to eq(2)
      expect(records).not_to be_empty
      expect(records[0]).to be_a(CustomerResource)
    end

    it "carries the client into each record, so relationships can be fetched" do
      expect(records.first.client).to be(client)
    end

    it "exposes the document's links and meta" do
      document = page(%w[cus_1], "self" => "#{base}/v2/customers")

      expect(list(document).links).to eq("self" => "#{base}/v2/customers")
      expect(list(document).meta).to eq("total" => 1)
    end

    it "is what production returns today: everything, in one response" do
      # The cursor work is unmerged, so there is no next link to follow.
      # docs/pagination.md.
      expect(records).not_to be_next_page
      expect(records.next_page).to be_nil
    end
  end

  describe "auto_paging_each" do
    it "walks every page" do
      first = page(%w[cus_1], "self" => "#{base}/v2/customers",
                              "next" => "#{base}/v2/customers?page%5Bafter%5D=cus_1")
      second = { "data" => [{ "type" => "customers", "id" => "cus_2" }],
                 "links" => { "self" => "#{base}/v2/customers?page%5Bafter%5D=cus_1" } }
      stub_request(:get, "#{base}/v2/customers")
        .with(query: { "page[after]" => "cus_1" })
        .to_return(status: 200, body: JSON.generate(second))

      expect(list(first).auto_paging_each.map(&:id)).to eq(%w[cus_1 cus_2])
    end

    it "follows a relative link against the configured base" do
      first = page(%w[cus_1], "next" => "/v2/customers?page%5Bafter%5D=cus_1")
      stub_request(:get, "#{base}/v2/customers")
        .with(query: { "page[after]" => "cus_1" })
        .to_return(status: 200, body: '{"data":[{"type":"customers","id":"cus_2"}]}')

      # The second page's records are what proves the link was followed.
      # Asserting only the first page's would pass just as well against a
      # client that silently ignored every relative link.
      expect(list(first).auto_paging_each.map(&:id)).to eq(%w[cus_1 cus_2])
      expect(a_request(:get, "#{base}/v2/customers").with(query: { "page[after]" => "cus_1" }))
        .to have_been_made
    end

    it "yields one page's records without a request when there is no next link" do
      expect(list(page(%w[cus_1])).auto_paging_each.map(&:id)).to eq(%w[cus_1])
    end

    it "stops immediately when the block breaks, without fetching another page" do
      first = page(%w[cus_1 cus_2], "next" => "#{base}/v2/customers?page=2")

      list(first).auto_paging_each { |record| break if record.id == "cus_1" }

      expect(a_request(:get, "#{base}/v2/customers").with(query: { "page" => "2" }))
        .not_to have_been_made
    end

    it "returns self so it can be chained" do
      records = list(page(%w[cus_1]))

      expect(records.auto_paging_each { |_| nil }).to be(records)
    end
  end

  describe "links that must not be followed" do
    it "refuses a next link to another origin" do
      # The bearer token authorises money movement. A pagination link is a URL
      # the response chose, so it is checked before the credential is attached.
      records = list(page(%w[cus_1], "next" => "https://evil.example/v2/customers"))

      expect { records.next_page? }.to raise_error(Edge::InsecureRedirectError)
      expect { records.auto_paging_each { |_| nil } }
        .to raise_error(Edge::InsecureRedirectError)
    end

    it "refuses a next link that only looks same-origin" do
      records = list(page(%w[cus_1], "next" => "https://api.tryedge.io.evil.example/v2/customers"))

      expect { records.next_page }.to raise_error(Edge::InsecureRedirectError)
    end
  end

  describe "loops" do
    it "raises on a cycle longer than one page" do
      # A -> B -> A. Remembering only the previous URL would spin forever.
      #
      # It raises rather than stopping quietly: a truncated walk looks exactly
      # like a complete one, and the caller cannot tell that records went
      # missing.
      back = { "data" => [{ "type" => "customers", "id" => "cus_2" }],
               "links" => { "self" => "#{base}/v2/customers?page=b",
                            "next" => "#{base}/v2/customers?page=a" } }
      stub_request(:get, "#{base}/v2/customers")
        .with(query: { "page" => "b" })
        .to_return(status: 200, body: JSON.generate(back))
      first = page(%w[cus_1], "self" => "#{base}/v2/customers?page=a",
                              "next" => "#{base}/v2/customers?page=b")

      expect { list(first).auto_paging_each { |_| nil } }
        .to raise_error(Edge::Error, /pagination links loop/)
    end

    it "keeps a filter value out of the loop error" do
      # The error names the URL, and a pagination URL carries the filter that
      # produced it — which can be a customer's email address. These messages
      # reach exception trackers.
      looping = "#{base}/v2/customers?filter%5Bemail%5D=ada@example.com"
      first = page(%w[cus_1], "self" => looping, "next" => looping)

      expect { list(first).auto_paging_each { |_| nil } }
        .to raise_error(Edge::Error) { |error| expect(error.message).not_to include("ada@") }
    end

    it "stops at max_auto_pages when every page is new" do
      # The second guard, for a server handing out an unbounded chain of
      # distinct URLs rather than a cycle.
      stub_request(:get, %r{#{base}/v2/customers\?page=\d+}).to_return do |request|
        number = request.uri.query_values["page"].to_i
        { status: 200,
          body: JSON.generate("data" => [{ "type" => "customers", "id" => "cus_#{number}" }],
                              "links" => { "self" => "#{base}/v2/customers?page=#{number}",
                                           "next" => "#{base}/v2/customers?page=#{number + 1}" }) }
      end
      first = page(%w[cus_0], "next" => "#{base}/v2/customers?page=1")
      records = described_class.new(document: first, client: client,
                                    resource_class: CustomerResource, max_auto_pages: 3)

      expect { records.auto_paging_each { |_| nil } }
        .to raise_error(Edge::Error, /stopped after 3 pages/)
    end
  end

  describe "#inspect" do
    it "reports the shape, not the records" do
      expect(list(page(%w[cus_1])).inspect)
        .to eq("#<Edge::ListObject CustomerResource count=1 next_link=false>")
    end

    it "does not raise on a link it would refuse to follow" do
      # A hostile or malformed next link is exactly when someone is inspecting
      # this object. An inspect that raises while an error reporter formats it
      # turns a diagnosable problem into a baffling one — so it reports whether
      # a link is present, which needs no network judgement.
      records = list(page(%w[cus_1], "next" => "https://evil.example/v2/customers"))

      expect(records.inspect).to include("next_link=true")
      expect { records.next_page? }.to raise_error(Edge::InsecureRedirectError)
    end
  end

  describe "max_auto_pages" do
    it "comes from the client configuration when not given" do
      # It had been a constant in ListObject that Configuration#max_auto_pages
      # never reached, so the documented setting did nothing at all.
      configured = Edge::Client.new(api_key: "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB",
                                    max_auto_pages: 7)
      records = described_class.new(document: page(%w[cus_1]), client: configured)

      expect(records.max_auto_pages).to eq(7)
    end

    it "prefers an explicit argument" do
      records = described_class.new(document: page(%w[cus_1]), client: client, max_auto_pages: 3)

      expect(records.max_auto_pages).to eq(3)
    end

    it "refuses a limit that would misbehave rather than failing mid-walk" do
      [nil, 0, -1, "10"].each do |bad|
        configured = Edge::Client.new(api_key: "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB",
                                      max_auto_pages: bad)

        expect { described_class.new(document: page(%w[cus_1]), client: configured) }
          .to raise_error(ArgumentError, /positive Integer/)
      end
    end
  end
end
