# frozen_string_literal: true

module Edge
  # A refund against a payment demand: `/v2/refund_demands`.
  #
  #   refund = Edge::RefundDemand.create(
  #     { reason: "customer_canceled", amount_cents: 25_00, idempotency_key: return.edge_key },
  #     relationships: { payment_demand: demand },
  #     retriable: true
  #   )
  #
  # ## Partial refunds
  #
  # A payment demand can be refunded several times, up to its original amount in
  # total. Send `amount_cents` for a partial refund; omit it to refund
  # **whatever remains**, which is the full amount only when nothing has been
  # refunded yet.
  #
  # The remaining balance counts every refund that is `pending`, `processing`
  # or `succeeded`: an in-flight refund reserves its amount, and a `failed` one
  # releases it. The check runs under a row lock on the payment demand, so two
  # concurrent refunds cannot both spend the same balance. Asking for more than
  # remains is a 422 on `amount_cents`; asking for anything once nothing
  # remains is a 422 on the payment demand; zero or a negative amount is a 422.
  #
  # The payment demand itself does not change. It stays `succeeded` however
  # much is refunded — there is no `refunded` state any more — and it
  # serializes no refunded total. To know what has been refunded, list the
  # refunds for that demand and sum the `succeeded` ones — or the `pending`,
  # `processing` and `succeeded` ones for what counts against the cap. Never
  # all of them: a `failed` refund is in the list and refunded nothing.
  #
  #   Edge::RefundDemand.list(filter: { "payment_demand.id" => demand.id })
  #
  # The server enforces the cap, so this client does not compute a balance or
  # refuse an amount before sending it. A client-side check would race.
  #
  # ## Safe to retry, with a key
  #
  # The server looks the `idempotency_key` up, scoped to the merchant, before
  # creating anything. A request that matches the original — same payment
  # demand, `amount_cents`, `reason` and `reason_note` — gets the original
  # refund back, and nothing is enqueued or emitted a second time. So
  # `retriable: true` is accepted here, with a key, which the client insists on:
  # without one the lookup misses and a repeat is a second refund.
  #
  # Reusing a key for a *different* request is a 422 on `idempotency_key`
  # ("has already been used for a different refund request"). A replay that
  # omits `amount_cents` matches whatever amount the original took, so the
  # retry of a "refund the rest" request is safe even after the balance has
  # reached zero.
  #
  # Payment demands document the same field and do not honour it (see
  # docs/payment-demands.md).
  #
  # ## `pending` is not "sent"
  #
  # A `201` means Edge stored the refund, reserved its amount and queued a job.
  # Nothing has reached the processor, and `processing` is set before it does.
  # `succeeded` means the gateway accepted the refund, not that the cardholder
  # has the money. See docs/refund-demands.md.
  class RefundDemand < Resource
    contract "refund_demands"

    # Values the server uses for `state`.
    STATES = %w[pending processing succeeded failed].freeze

    # Reasons the API accepts. `custom` requires `reason_note`, and postdates
    # the vendored OpenAPI snapshot — which is why the manifest records it as
    # `snapshot_stale`.
    REASONS = %w[
      service_not_delivered duplicate_charge unauthorized_transaction technical_issue
      customer_canceled dissatisfied_experience compliance_issue custom
    ].freeze

    # The longest `reason_note` the server stores.
    REASON_NOTE_LIMIT = 500

    # What a refund create actually takes from the caller.
    #
    # `amount_currency` is inherited from the payment demand and cannot be
    # changed. It is accepted because sending the demand's own currency is
    # harmless and a different real one is a 422 naming the field — not the
    # 500 it used to be.
    # See `reject_unsupported_currency!` for the case that still 500s.
    CREATABLE = %w[reason reason_note idempotency_key amount_cents amount_currency].freeze

    # The only currency the payment schema has, so the only one a refund can
    # inherit.
    CURRENCY = "USD"

    # Keywords `create` consumes, which are never attributes.
    RESERVED = %w[client relationships retriable].freeze

    class << self
      # Creates a refund. Omit `amount_cents` to refund everything that has not
      # already been refunded or reserved by an in-flight refund.
      def create(attributes = {}, relationships: nil, **rest)
        written = stringify(attributes).merge(stringify(rest))
        require_payment_demand!(relationships)
        require_reason!(written)
        reject_unnoted_custom!(written)
        reject_unsupported_currency!(written)
        writable_on_create!(written)
        super
      end

      private

      # The server reads the payment demand linkage before validating anything,
      # so a request without one is a 500 rather than a
      # `payment_demand can't be blank` validation error. There is nothing else
      # to refund *from*, so this is the one linkage that is genuinely
      # mandatory.
      def require_payment_demand!(relationships)
        return if stringify(relationships || {}).key?("payment_demand")

        raise ArgumentError,
              "refund_demands.create needs the payment demand it refunds: " \
              "`relationships: { payment_demand: demand }`. The API reads the linkage " \
              "before validating anything, so a request without it is answered with a 500."
      end

      # Required by the server. Refused here because the API's own message for
      # a missing one names no field.
      def require_reason!(written)
        return unless written["reason"].to_s.strip.empty?

        raise ArgumentError,
              "refund_demands.reason is required; one of #{REASONS.join(", ")}."
      end

      # A refund create takes `reason`, `reason_note`, `idempotency_key`, and
      # the amount and currency. Everything else — `state` above all — is
      # accepted by the endpoint and discarded: every new refund starts
      # `pending` whatever was sent.
      def writable_on_create!(written)
        offered = written.keys - CREATABLE - RESERVED
        return if offered.empty?

        raise ArgumentError,
              "refund_demands.create does not accept #{offered.sort.join(", ")}. The API " \
              "applies only #{CREATABLE.join(", ")}; anything else is answered 201 and discarded."
      end

      # With `amount_cents` present, the server errors on a currency code it
      # does not know before validating it — so `"XYZ"` or `"US"` is a 500,
      # while `"EUR"` is a 422. Only one currency can ever match, so
      # anything but it is refused here rather than sorted into those two.
      def reject_unsupported_currency!(written)
        return unless written.key?("amount_currency")
        return if written["amount_currency"].to_s == CURRENCY

        raise ArgumentError,
              "refund_demands.amount_currency must be #{CURRENCY.inspect} — it is inherited " \
              "from the payment demand and cannot be changed. Omit it."
      end

      # `custom` without a note is rejected server-side, and the message that
      # comes back names no field. Cheaper to catch here.
      def reject_unnoted_custom!(written)
        note = written["reason_note"].to_s
        if written["reason"].to_s == "custom" && note.strip.empty?
          raise ArgumentError,
                "refund_demands.reason \"custom\" needs a reason_note saying what it was."
        end
        return if note.length <= REASON_NOTE_LIMIT

        raise ArgumentError,
              "refund_demands.reason_note is #{note.length} characters; the server stores at " \
              "most #{REASON_NOTE_LIMIT}."
      end
    end

    # Refund states. Each answers false for a state this client has not heard
    # of rather than raising.
    #
    # A successful refund emits `transaction.refund_demands.updated`, **not**
    # `.succeeded` — there is no such event. `updated` also fires on
    # `pending → processing`, so a consumer watching webhooks keys off
    # `updated` and then reads `#succeeded?` here. A failed refund emits only
    # `transaction.refund_demands.failed`.
    def pending? = state == "pending"
    def processing? = state == "processing"
    def succeeded? = state == "succeeded"

    # Terminal, and releases the amount it had reserved: the payment demand
    # can be refunded by that much again.
    def failed? = state == "failed"

    # True while the refund is still moving — and still holding its amount
    # against the payment demand's remaining balance. False for an unknown
    # state, so a poller stops and looks rather than spinning. Edge has no
    # sweeper for stuck refunds, so give any poll a deadline.
    def in_flight? = pending? || processing?

    # True once the refund has stopped moving, whichever way it went.
    def settled? = succeeded? || failed?

    def state_known? = STATES.include?(state)

    def custom_reason? = self[:reason] == "custom"
  end
end
