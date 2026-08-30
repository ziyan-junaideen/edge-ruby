# frozen_string_literal: true

RSpec.describe Edge::APIError do
  def jsonapi_errors(*errors)
    { "errors" => errors }
  end

  describe "the exception the status maps to" do
    {
      400 => Edge::BadRequestError,
      401 => Edge::AuthenticationError,
      403 => Edge::PermissionError,
      404 => Edge::NotFoundError,
      406 => Edge::NotAcceptableError,
      409 => Edge::ConflictError,
      415 => Edge::UnsupportedMediaTypeError,
      422 => Edge::InvalidRequestError,
      429 => Edge::RateLimitError,
      500 => Edge::ServerError,
      503 => Edge::ServerError
    }.each do |status, klass|
      it "raises #{klass} for #{status}" do
        response = Edge::Response.new(status: status, headers: {}, body: "{}")

        expect { response.raise_on_error! }.to raise_error(klass)
      end
    end

    it "falls back to APIError for an undocumented 4xx" do
      response = Edge::Response.new(status: 418, headers: {}, body: "{}")

      expect { response.raise_on_error! }.to raise_error(described_class)
    end

    it "does not raise for a 2xx" do
      response = Edge::Response.new(status: 200, headers: {}, body: "{}")

      expect(response.raise_on_error!).to be(response)
    end
  end

  describe "a body that is not JSON" do
    # Auth failures come back as a bare reason phrase with no JSON and no
    # vnd.api+json content type (http_authorization_plug.ex:30-50). Every other
    # error path returns JSON:API, so this is the case a client forgets.
    it "produces a typed error, not a JSON::ParserError" do
      response = Edge::Response.new(
        status: 401, headers: { "content-type" => "text/plain" }, body: "Unauthorized"
      )

      expect { response.raise_on_error! }.to raise_error(Edge::AuthenticationError, /Unauthorized/)
    end

    it "keeps the raw body for diagnosis" do
      response = Edge::Response.new(status: 422, headers: {}, body: "Unprocessable Content")

      expect { response.raise_on_error! }.to raise_error(Edge::InvalidRequestError) { |error|
        expect(error.raw_body).to eq("Unprocessable Content")
        expect(error.errors).to be_empty
      }
    end

    it "survives an HTML error page from a proxy" do
      response = Edge::Response.new(status: 502, headers: {}, body: "<html><h1>Bad Gateway</h1>")

      expect { response.raise_on_error! }.to raise_error(Edge::ServerError, /Bad Gateway/)
    end

    it "survives an empty body" do
      response = Edge::Response.new(status: 500, headers: {}, body: "")

      expect { response.raise_on_error! }.to raise_error(Edge::ServerError, "HTTP 500")
    end

    it "truncates a very long body rather than filling a log" do
      response = Edge::Response.new(status: 500, headers: {}, body: "x" * 5_000)

      expect { response.raise_on_error! }.to raise_error(Edge::ServerError) { |error|
        expect(error.message.length).to be < 600
        expect(error.message).to end_with("...")
        # The full body is still reachable for anyone who needs it.
        expect(error.raw_body.length).to eq(5_000)
      }
    end
  end

  describe "JSON:API error objects" do
    let(:response) do
      Edge::Response.new(
        status: 422,
        headers: { "x-request-id" => "req_123" },
        body: JSON.generate(jsonapi_errors(
                              { "status" => "422", "code" => "too_small",
                                "title" => "is invalid",
                                "detail" => "must be greater than zero",
                                "source" => { "pointer" => "/data/attributes/amount_cents" } },
                              { "status" => "422", "title" => "is invalid",
                                "detail" => "is not a supported currency",
                                "source" => { "pointer" => "/data/attributes/amount_currency" } }
                            ))
      )
    end

    it "parses each error" do
      expect { response.raise_on_error! }.to raise_error(Edge::InvalidRequestError) { |error|
        expect(error.errors.length).to eq(2)
        expect(error.errors.first.code).to eq("too_small")
        expect(error.errors.first.pointer).to eq("/data/attributes/amount_cents")
      }
    end

    it "maps pointers onto attribute names for a form" do
      expect { response.raise_on_error! }.to raise_error(Edge::InvalidRequestError) { |error|
        expect(error.errors_by_attribute).to eq(
          amount_cents: ["must be greater than zero"],
          amount_currency: ["is not a supported currency"]
        )
      }
    end

    it "carries the request id" do
      expect { response.raise_on_error! }.to raise_error(Edge::InvalidRequestError) { |error|
        expect(error.request_id).to eq("req_123")
        expect(error.message).to include("req_123")
      }
    end

    it "maps parameter errors separately from attribute errors" do
      # A rejected page[limit] names a parameter, not an attribute.
      response = Edge::Response.new(
        status: 400, headers: {},
        body: JSON.generate(jsonapi_errors(
                              { "detail" => "Pagination limit must be between 1 and 100",
                                "source" => { "parameter" => "page[limit]" } }
                            ))
      )

      expect { response.raise_on_error! }.to raise_error(Edge::BadRequestError) { |error|
        expect(error.errors_by_parameter)
          .to eq("page[limit]" => ["Pagination limit must be between 1 and 100"])
        expect(error.errors_by_attribute).to be_empty
      }
    end

    it "ignores a pointer that does not name an attribute" do
      response = Edge::Response.new(
        status: 422, headers: {},
        body: JSON.generate(jsonapi_errors(
                              { "detail" => "is invalid", "source" => { "pointer" => "/data" } }
                            ))
      )

      expect { response.raise_on_error! }.to raise_error(Edge::InvalidRequestError) { |error|
        expect(error.errors_by_attribute).to be_empty
        expect(error.errors.first.attribute).to be_nil
      }
    end

    it "tolerates a malformed errors member" do
      response = Edge::Response.new(
        status: 422, headers: {}, body: JSON.generate("errors" => ["not an object", nil])
      )

      expect { response.raise_on_error! }.to raise_error(Edge::InvalidRequestError)
    end
  end

  describe "redaction" do
    it "does not echo an API key that appears in an error body" do
      key = "ept_live_sQsnYGFoLvE2Qt7tmsvuDESB"
      response = Edge::Response.new(status: 400, headers: {}, body: "bad token #{key}")

      expect { response.raise_on_error! }.to raise_error(described_class) { |error|
        expect(error.message).not_to include(key)
        expect(error.message).to include("[FILTERED]")
        # The mode survives; it is useful and is not a secret.
        expect(error.message).to include("ept_live_")
      }
    end

    it "does not echo a key carried in a JSON:API detail" do
      key = "ept_sandbox_sQsnYGFoLvE2"
      response = Edge::Response.new(
        status: 401, headers: {},
        body: JSON.generate(jsonapi_errors({ "detail" => "token #{key} is archived" }))
      )

      expect { response.raise_on_error! }.to raise_error(described_class) { |error|
        expect(error.message).not_to include(key)
        expect(error.errors.first.detail).not_to include(key)
      }
    end
  end
end
