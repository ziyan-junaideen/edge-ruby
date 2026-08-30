# frozen_string_literal: true

module Edge
  # A billing or shipping address belonging to a customer:
  # `/v2/consumer_addresses`.
  #
  #   Edge::ConsumerAddress.create(
  #     { line_1: "1 Example Street", city: "London", country: "GB" },
  #     relationships: { customer: customer }
  #   )
  #
  # An address is soft-deleted server-side — `discarded_at` — but the API
  # exposes no route to discard one, so this client offers no `#discard`.
  class ConsumerAddress < Resource
    contract "consumer_addresses"

    def discarded? = !self[:discarded_at].nil?
  end
end
