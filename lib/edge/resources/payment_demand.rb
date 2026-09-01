# frozen_string_literal: true

module Edge
  # A charge against a stored payment method: `/v2/payment_demands`.
  #
  #   demand = Edge::PaymentDemand.create(
  #     {
  #       amount_cents: 5_00, amount_currency: "USD", purchase_kind: "order",
  #       purchase_reference: order.number, confirmed: true,
  #       idempotency_key: order.edge_idempotency_key, payer_timezone: "Europe/London"
  #     }.merge(order.threeds_results),
  #     relationships: {
  #       payer: customer, payment_method: method_id, billing_address: address
  #     }
  #   )
  #   demand.processor_state   # => "pending"
  #
  # ## This endpoint returns two different kinds of record
  #
  # `POST /v2/payment_demands` creates a **payment intent** unless the request
  # says `confirmed: true`, and the intent is rendered through the payment
  # demand view — same `type`, same route, same readers
  # (`payment_demands_controller.ex`, `create_payment_demand_request/2`).
  # Nothing in the response announces which one you hold except
  # `processor_state`, whose two sets of values do not overlap. `#intent?` and
  # `#demand?` are that comparison, written down once.
  #
  # It matters because only a demand has been charged. An intent is a parked
  # request that has taken no money and holds no authorization.
  #
  # ## The two ways to charge
  #
  # **One step** — `confirmed: true` on create. The charge is enqueued
  # immediately and the record comes back `pending`. This is what a checkout
  # wants, and it is the only shape where a failure to create and a failure to
  # charge cannot be separated by a crash in between.
  #
  # **Two steps** — create without `confirmed`, then `#confirm`. Create
  # validates far less: an intent was accepted here with no billing address
  # and no `purchase_kind`, and `#confirm` then rejected it for both. Anything
  # missing surfaces at confirm time, not at create time.
  #
  # `#confirm` also retries a **failed** demand, which is the other half of
  # its guard (`is_confirmable_demand`, `payment.ex:26`) and the reason it can
  # never be retried automatically: replaying it charges again.
  #
  # ## What this class deliberately does not have
  #
  # **No `#capture` and no `#void`.** Not an omission — the API has no route
  # for either, `confirm` is not capture, and deferred capture is unsupported
  # today for PCI compliance reasons on a timeline measured in years. A method
  # that 404'd would read as a server fault rather than as a capability that
  # does not exist. See docs/payment-demands.md and RB-1/FU-18.
  #
  # **No refunded total and no `#amount_refunded`.** `amount_refunded_cents`
  # is documented by Edge and served by nothing; no shipped server tracks a
  # cumulative refund. See RB-2 and `documented_only_attributes`.
  #
  # **No automatic retries.** See `.create` below — this is the one worth
  # reading before writing a retry loop of your own.
  class PaymentDemand < Resource
    contract "payment_demands"

    # `PATCH /v2/payment_demands/{id}/confirm`.
    custom_action :confirm

    # `processor_state` values that belong to a payment demand — a record that
    # has been sent to the processor (`PaymentDemand.processor_states/0`).
    DEMAND_STATES = %w[pending processing succeeded reversed refunded failed disputed].freeze

    # ...and the ones that belong to a payment intent, which this endpoint
    # also returns (`payment_intent.ex:20-25`). Disjoint from DEMAND_STATES,
    # which is the only reason telling the two apart is possible at all.
    INTENT_STATES = %w[incomplete ready confirmed canceled].freeze

    # Attributes `PATCH /v2/payment_demands/{id}` actually casts, on both a
    # demand (`payment_demand.ex:421-439`) and an intent
    # (`payment_intent.ex:155-180`): the charge, addendum and settings groups.
    # `fee_cents` is cast there too and is deliberately absent — it is server
    # computed on create, and letting a caller set their own fee on update is
    # not something to enable on this evidence.
    UPDATABLE = %w[
      description amount_cents amount_currency discount_cents purchase_reference
      purchase_kind shipping_detail tax_detail line_items email_receipt
    ].freeze

    # Keywords `create` and `update` consume, which are never attributes.
    RESERVED = %w[client relationships retriable].freeze

    class << self
      # Creates a payment intent, or — with `confirmed: true` — a payment
      # demand that charges immediately. See the class documentation.
      #
      # **`retriable: true` is refused, and that is not a client limitation.**
      # `payment_demands.idempotency_key` is documented as "a unique value
      # that prevents double charging"; on every shipped server it is not cast
      # on create, no replay lookup runs, and no unique index fires. Two
      # identical POSTs sharing one key produce two demands and two charges —
      # verified, not inferred. `contract/manifest.yml` records
      # `idempotent_writes: false` so `retriable:` cannot be set here, and
      # Transport refuses it a second time.
      #
      # TODO: a fix is written and working — a per-merchant unique index and a
      # replay lookup, verified against a local instance returning one record
      # for two POSTs — but it is unmerged and undeployed. When it ships,
      # re-run the two-POST check against a deployed server, add
      # `payment_demands` to `IDEMPOTENT` in `contract/bin/extract_manifest.rb`,
      # regenerate, and `retriable: true` starts working with no other change.
      # Until then: **send an idempotency key anyway** — it costs nothing and
      # it is what makes the eventual replay find your record — but do not
      # retry a create on a timeout. Read the demand back by
      # `purchase_reference` instead. See docs/release-blockers.md, FU-20.
      def create(attributes = {}, **rest)
        reject_manual_capture!(merged_attributes(attributes, rest))
        super
      end

      # Updates a payment intent, or a payment demand that has **failed** —
      # `json_api_update_changeset/2` ends in
      # `validate_from_states(:processor_state, :failed)`, so a succeeded or
      # pending demand cannot be edited at all.
      #
      # Accepts far less than `create` does. The update changesets on both
      # kinds of record (`payment_demand.ex:421`, `payment_intent.ex:155`)
      # cast the charge, addendum and settings groups and the relationship
      # ids, and nothing else — so the 3DS results, `capture_method` and
      # `idempotency_key` are all accepted by the endpoint and dropped without
      # comment. See UPDATABLE.
      def update(id, attributes = {}, **rest)
        written = writable_on_update!(merged_attributes(attributes, rest))
        reject_manual_capture!(written)
        super
      end

      private

      # `capture_method: "manual"` is accepted by the API and reaches the
      # processor as an NMI `auth` rather than a `sale`
      # (`remote_client/nmi.ex:127`). Nothing can then capture or void it:
      # `capture_transaction/1` and `cancel_transaction/1` exist in the tree
      # with no callers and no route. The money sits authorised against a
      # cardholder's account until the processor expires it, and no Edge API
      # call can either take it or release it.
      #
      # So this is refused rather than passed through. It is the one place
      # this client declines something the server would accept, and it is
      # because "the server accepted it" is exactly what makes the outcome
      # invisible. `client.post("v2/payment_demands", body: …)` still sends
      # whatever you like.
      def reject_manual_capture!(written)
        return unless written["capture_method"].to_s == "manual"

        raise ArgumentError,
              "capture_method: \"manual\" authorises the card and then strands it. The API has " \
              "no capture and no void route, so nothing can take or release the authorization " \
              "afterwards — it sits until the processor expires it. Deferred capture is not " \
              "supported today (docs/release-blockers.md, RB-1). Omit capture_method for an " \
              "immediate charge."
      end

      # The same merge `Operations::Body#write_attributes` performs, in the
      # same order, so a guard reads exactly the value the request will send.
      #
      # Reading the two sources separately was a real bypass: `**rest` wins
      # the merge, so `create(defaults, capture_method: "manual")` — the
      # ordinary way to layer a per-order override onto a shared default hash
      # — let the guard find `"automatic"` in the positional hash, pass, and
      # send `"manual"` on the wire.
      def merged_attributes(attributes, rest)
        stringify(attributes).merge(stringify(rest))
      end

      # `update` reaches a changeset that casts only these. Anything else the
      # view declares is accepted, answered 200, and silently discarded — the
      # failure `reject_readonly!` exists to prevent, which the resource-level
      # `writable` flag cannot express because it has no per-operation
      # dimension.
      #
      # The reserved keywords are not attributes and are left alone.
      def writable_on_update!(written)
        offered = written.keys - UPDATABLE - RESERVED
        return written if offered.empty?

        raise ArgumentError,
              "payment_demands.update does not accept #{offered.sort.join(", ")}. The update " \
              "changeset casts only #{UPDATABLE.join(", ")} and the relationship ids; anything " \
              "else is answered 200 and discarded. Set them when the demand is created."
      end
    end

    # True when this record is a payment intent: created without
    # `confirmed: true`, charged nothing, holding no authorization.
    def intent? = INTENT_STATES.include?(processor_state)

    # True when this record is a payment demand that has reached the
    # processor. False for an intent **and** for a state this client does not
    # know, which is the safe direction: a new state must not be read as "this
    # was charged".
    def demand? = DEMAND_STATES.include?(processor_state)

    # False for a `processor_state` in neither set. Every predicate below
    # answers false for an unknown state rather than raising, so a state added
    # server-side cannot break a running integration — but it also means
    # "everything false" is ambiguous, and this is how to tell that apart from
    # a state that is genuinely none of them.
    def state_known? = intent? || demand?

    # Payment demand states.
    def pending? = processor_state == "pending"
    def processing? = processor_state == "processing"
    def succeeded? = processor_state == "succeeded"
    def reversed? = processor_state == "reversed"
    def failed? = processor_state == "failed"
    def disputed? = processor_state == "disputed"

    # Any refund at all moves a demand here, whatever its amount: nothing
    # server-side tracks a refunded total, and a 1-cent refund closes a
    # 100-dollar demand (docs/release-blockers.md, FU-16). So this means
    # "refunded", never "refunded in full".
    def refunded? = processor_state == "refunded"

    # Payment intent states — except `confirmed`, which has deliberately no
    # predicate. `#confirmed` is already the boolean attribute the create
    # request carries, and a `#confirmed?` one character away from it, meaning
    # the intent's `processor_state` instead, is a bug waiting to be written.
    # Read `processor_state == "confirmed"` for that one.
    #
    # The attribute is not a substitute either: a demand created in one step
    # with `confirmed: true` came back with `confirmed` **nil**, so it
    # describes neither the request nor the state reliably. `#demand?` is the
    # question worth asking.
    def incomplete? = processor_state == "incomplete"
    def ready? = processor_state == "ready"
    def canceled? = processor_state == "canceled"

    # True when the charge is still moving and worth polling for. False for
    # an unknown state, so a poller stops and looks rather than spinning on a
    # state it cannot interpret.
    def in_flight? = pending? || processing?

    # Line items as the server sent them: an array of hashes, or `[]`. Not
    # coerced into objects — the embedded schema has twelve optional fields
    # and a wrapper would have to invent a meaning for each absent one.
    def line_items = self[:line_items] || []

    # True when the card issuer's address and security-code checks both came
    # back matching. Nil-safe, and false whenever either is missing: these are
    # `unverified`/`unprocessed` on a record that has not reached the
    # processor, and treating "not checked" as "checked and fine" is the
    # failure this predicate exists to prevent.
    def verification_passed?
      self[:cvc2_check] == "match" &&
        self[:address_line1_verification] == "match" &&
        self[:postal_code_verification] == "match"
    end
  end
end
