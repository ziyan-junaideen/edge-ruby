# frozen_string_literal: true

module Edge
  # A person or business a merchant transacts with: `/v2/customers`.
  #
  #   customer = Edge::Customer.create(email: "ada@example.com", name: "Ada Lovelace")
  #   customer.addresses.fetch
  #
  # `email`, `name` and `phone_number` are personal data. They are readable
  # here and filtered out of every log line, error message and `inspect` the
  # client produces; `#raw` is the documented exception.
  class Customer < Resource
    contract "customers"

    # True once the merchant has blocked this customer. There is no unblock
    # route, and `blocked_at` is not writable, so this reports state rather
    # than offering to change it.
    def blocked? = !self[:blocked_at].nil?
  end
end
