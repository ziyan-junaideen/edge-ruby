# frozen_string_literal: true

module Edge
  # A refund against a payment demand: `/v2/refund_demands`.
  #
  #   refund = Edge::RefundDemand.create(
  #     { reason: "duplicate_charge", idempotency_key: order.refund_key },
  #     relationships: { payment_demand: demand },
  #     retriable: true
  #   )
  #
  # ## Refunds are all-or-nothing, whatever amount you send
  #
  # **Any refund closes its payment demand.** The demand moves to `refunded`
  # and no second refund against it is possible — a 100-cent refund closed a
  # 10,000-cent demand, verified against a running instance. Nothing
  # server-side tracks a cumulative refunded total, and there is no remaining
  # balance to compute one from.
  #
  # So `amount_cents` is a **partial payout on a closed demand**, not a partial
  # refund in the sense a commerce system means. Omitting it refunds the full
  # payment demand amount, which is almost always what you want; sending a
  # smaller value refunds that much and forfeits the rest. This client does not
  # hide the field, because a merchant may genuinely want to return part of a
  # payment and accept that the demand is then closed — but it will not let
  # that happen by accident. See docs/release-blockers.md, FU-16.
  #
  # ## The one write in this API that is safe to retry
  #
  # `refund_demands` is the only resource with a working replay contract:
  # `replay_refund_demand/3` (`core/transactions.ex:897`) looks the
  # `idempotency_key` up before inserting and returns the original record.
  # Verified: one key, two requests, one refund. So `retriable: true` is
  # accepted here — with a key, which the client insists on, because without
  # one the lookup misses and a repeat is a second refund.
  #
  # Payment demands document the same field and do not honour it (FU-20).
  class RefundDemand < Resource
    contract "refund_demands"

    # `Ecto.Enum` values for `state` (`RefundDemand.statuses/0`). `errored` is
    # the one people miss: it is distinct from `failed` and is terminal.
    STATES = %w[pending processing succeeded failed errored].freeze

    # Reasons the API accepts. `custom` requires `reason_note`, and postdates
    # the vendored OpenAPI snapshot — which is why the manifest records it as
    # `snapshot_stale`.
    REASONS = %w[
      service_not_delivered duplicate_charge unauthorized_transaction technical_issue
      customer_canceled dissatisfied_experience compliance_issue custom
    ].freeze

    # The longest `reason_note` the server stores.
    REASON_NOTE_LIMIT = 500

    # What `refund_payment_demand_changeset/2` actually takes from the caller.
    # `amount_currency` is inherited and is refused separately, with its own
    # explanation, because sending it is a 500 rather than a silent drop.
    CREATABLE = %w[reason reason_note idempotency_key amount_cents].freeze

    # Keywords `create` consumes, which are never attributes.
    RESERVED = %w[client relationships retriable].freeze

    class << self
      # Creates a refund. Omit `amount_cents` for a full refund, which is what
      # the API does by default and what closing the demand actually means.
      def create(attributes = {}, relationships: nil, **rest)
        written = stringify(attributes).merge(stringify(rest))
        require_payment_demand!(relationships)
        require_reason!(written)
        reject_currency!(written)
        reject_unnoted_custom!(written)
        writable_on_create!(written)
        super
      end

      private

      # `refund_demands_controller.ex:147` destructures
      # `relationships: %{payment_demand: payment_demand}` and reads
      # `payment_demand.merchant` from it immediately, so a request without one
      # is a 500 rather than the `payment_demand can't be blank` the changeset
      # would give. There is nothing else to refund *from*, so this is the one
      # linkage that is genuinely mandatory.
      def require_payment_demand!(relationships)
        return if stringify(relationships || {}).key?("payment_demand")

        raise ArgumentError,
              "refund_demands.create needs the payment demand it refunds: " \
              "`relationships: { payment_demand: demand }`. The controller reads the linkage " \
              "before validating anything, so a request without it is answered with a 500."
      end

      # `validate_required([…, :reason])`. Refused here because the API's own
      # message for a missing one names no field (FU-19).
      def require_reason!(written)
        return unless written["reason"].to_s.strip.empty?

        raise ArgumentError,
              "refund_demands.reason is required; one of #{REASONS.join(", ")}."
      end

      # `refund_payment_demand_changeset/2` casts `reason` and `reason_note`,
      # takes `idempotency_key` through `idempotency_cast_changeset/2`, and
      # `put_change`s the two amounts. Everything else — `state` above all — is
      # accepted by the endpoint and discarded: `state` is forced to `:pending`
      # by `Ecto.Changeset.change` before any cast runs.
      def writable_on_create!(written)
        offered = written.keys - CREATABLE - RESERVED
        return if offered.empty?

        raise ArgumentError,
              "refund_demands.create does not accept #{offered.sort.join(", ")}. The changeset " \
              "casts only #{CREATABLE.join(", ")}; anything else is answered 201 and discarded."
      end

      # `amount_currency` is documented as a string and is an
      # `Ecto.Enum<[:USD]>` set with `put_change`, which does not cast — so the
      # documented `"USD"` is a 500, not a validation error. Omitting it
      # succeeds, because the value is inherited from the payment demand and
      # was never the caller's to set. Verified against a running instance.
      # See docs/release-blockers.md, FU-17.
      def reject_currency!(written)
        return unless written.key?("amount_currency")

        raise ArgumentError,
              "refund_demands.amount_currency cannot be sent: it is inherited from the payment " \
              "demand, and the server sets it with put_change, which does not cast — so the " \
              "documented \"USD\" is answered with a 500 rather than a validation error. " \
              "Omit it. See docs/release-blockers.md, FU-17."
      end

      # `custom` without a note is rejected server-side, and the message that
      # comes back names no field (FU-19). Cheaper to catch here.
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
    # `.succeeded` — there is no such event. A consumer watching webhooks keys
    # off `updated` and then reads `#succeeded?` here.
    def pending? = state == "pending"
    def processing? = state == "processing"
    def succeeded? = state == "succeeded"
    def failed? = state == "failed"

    # Distinct from `failed?`, and easy to miss: `errored` is its own terminal
    # state. A handler that only checks `failed?` treats an errored refund as
    # still in progress and waits forever.
    def errored? = state == "errored"

    # True while the refund is still moving. False for an unknown state, so a
    # poller stops and looks rather than spinning.
    def in_flight? = pending? || processing?

    # True once the refund has stopped moving, whichever way it went.
    def settled? = succeeded? || failed? || errored?

    def state_known? = STATES.include?(state)

    def custom_reason? = self[:reason] == "custom"
  end
end
