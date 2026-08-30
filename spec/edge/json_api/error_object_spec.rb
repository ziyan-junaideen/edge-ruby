# frozen_string_literal: true

RSpec.describe Edge::JSONAPI::ErrorObject do
  describe "#to_s" do
    # The API answers a payment demand created without the 3DS fields with
    # nine errors whose title is the identical string "can't be blank". The
    # pointer is the only part that says which field, so a message that drops
    # it repeats one useless sentence nine times.
    it "names the attribute a pointer refers to" do
      error = described_class.new("title" => "can't be blank",
                                  "source" => { "pointer" => "/data/attributes/payer_timezone" })

      expect(error.to_s).to eq("payer_timezone: can't be blank")
    end

    it "names the query parameter when the error is about one" do
      error = described_class.new("title" => "is invalid",
                                  "source" => { "parameter" => "page[limit]" })

      expect(error.to_s).to eq("page[limit]: is invalid")
    end

    it "falls back to the raw pointer for a member that is not an attribute" do
      # A relationship pointer is just as useful to a caller, and inventing a
      # short name for it would misreport where the fault is.
      error = described_class.new("title" => "can't be blank",
                                  "source" => { "pointer" => "/data/relationships/payer" })

      expect(error.to_s).to eq("/data/relationships/payer: can't be blank")
    end

    it "is the text alone when the error points at nothing" do
      expect(described_class.new("title" => "Unauthorized").to_s).to eq("Unauthorized")
    end

    it "keeps title and detail together, in that order" do
      error = described_class.new("title" => "is invalid", "detail" => "must be one of USD",
                                  "source" => { "pointer" => "/data/attributes/amount_currency" })

      expect(error.to_s).to eq("amount_currency: is invalid: must be one of USD")
    end

    it "ignores an empty pointer rather than rendering a bare colon" do
      error = described_class.new("title" => "can't be blank", "source" => { "pointer" => "" })

      expect(error.to_s).to eq("can't be blank")
    end

    it "is empty when there is no readable text, whatever it points at" do
      # APIError falls back to the body excerpt on an empty message. An error
      # carrying only a code — `{"errors":[{"code":"card_declined"}]}` — must
      # not defeat that by returning a bare attribute name.
      error = described_class.new("code" => "card_declined",
                                  "source" => { "pointer" => "/data/attributes/amount_cents" })

      expect(error.to_s).to eq("")
    end
  end

  describe "the message an APIError builds from these" do
    it "distinguishes errors that would otherwise read identically" do
      body = JSON.generate(
        "errors" => [
          { "status" => 422, "title" => "can't be blank",
            "source" => { "pointer" => "/data/attributes/purchase_reference" } },
          { "status" => 422, "title" => "can't be blank",
            "source" => { "pointer" => "/data/attributes/payer_timezone" } }
        ]
      )
      error = Edge::APIError.new(status: 422, body: body,
                                 errors: described_class.from(JSON.parse(body)))

      expect(error.message)
        .to eq("HTTP 422 purchase_reference: can't be blank; payer_timezone: can't be blank")
    end
  end
end
