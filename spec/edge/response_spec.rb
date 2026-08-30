# frozen_string_literal: true

RSpec.describe Edge::Response do
  def response(status: 200, headers: {}, body: nil)
    described_class.new(status: status, headers: headers, body: body)
  end

  describe "#success?" do
    it "is true for 2xx" do
      expect(response(status: 200)).to be_success
      expect(response(status: 201)).to be_success
      expect(response(status: 299)).to be_success
    end

    it "is false outside 2xx" do
      expect(response(status: 199)).not_to be_success
      expect(response(status: 300)).not_to be_success
      expect(response(status: 500)).not_to be_success
    end
  end

  describe "#data" do
    # The class promises never to raise here. The API is not uniformly JSON —
    # auth failures are plain text — and a proxy can return anything at all.
    it "parses a JSON:API document" do
      expect(response(body: '{"data":{"id":"1"}}').data).to eq("data" => { "id" => "1" })
    end

    it "returns nil for a nil body" do
      expect(response(body: nil).data).to be_nil
    end

    it "returns nil for an empty or whitespace body" do
      expect(response(body: "").data).to be_nil
      expect(response(body: "   \n ").data).to be_nil
    end

    it "returns nil for a body that is not JSON" do
      expect(response(body: "Unauthorized").data).to be_nil
      expect(response(body: "<html><h1>502</h1></html>").data).to be_nil
    end

    it "returns nil for truncated JSON" do
      expect(response(body: '{"data":').data).to be_nil
    end

    it "does not raise on invalid bytes tagged as UTF-8" do
      # A proxy returning latin-1 under a utf-8 content type. Running a regex
      # or String#strip over these bytes raises ArgumentError, which would turn
      # a server error into a crash inside the client.
      body = "\xff\xfe not json".dup.force_encoding("UTF-8")

      expect { response(body: body).data }.not_to raise_error
      expect(response(body: body).data).to be_nil
    end

    it "does not raise on deeply nested JSON" do
      # JSON::NestingError is a ParserError, so this is caught with the rest.
      body = ("[" * 200) + ("]" * 200)

      expect { response(body: body).data }.not_to raise_error
    end

    it "passes through a body Faraday already parsed" do
      expect(response(body: { "data" => [] }).data).to eq("data" => [])
      expect(response(body: [1, 2]).data).to eq([1, 2])
    end

    it "handles JSON that parses to a scalar" do
      expect(response(body: "123").data).to eq(123)
      expect(response(body: '"text"').data).to eq("text")
      expect(response(body: "null").data).to be_nil
    end

    it "parses once and memoises" do
      subject = response(body: '{"a":1}')

      expect(subject.data).to equal(subject.data)
    end
  end

  describe "headers" do
    it "downcases names so lookups do not depend on the adapter" do
      subject = response(headers: { "X-Request-Id" => "req_1", "Content-Type" => "text/plain" })

      expect(subject.headers).to eq("x-request-id" => "req_1", "content-type" => "text/plain")
    end

    it "tolerates nil headers" do
      expect(response(headers: nil).headers).to eq({})
    end
  end

  describe "#raise_on_error!" do
    it "returns itself on success" do
      subject = response(status: 200, body: "{}")

      expect(subject.raise_on_error!).to be(subject)
    end

    it "raises on a non-JSON body without a parser error" do
      expect do
        response(status: 500, body: "\xff\xfe boom".dup.force_encoding("UTF-8")).raise_on_error!
      end
        .to raise_error(Edge::ServerError)
    end
  end
end
