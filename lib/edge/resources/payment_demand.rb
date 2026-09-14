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
  # `pending` means Edge has stored the demand and queued a background job —
  # nothing has been sent to the processor or the card networks yet, and
  # `processing` is set before the processor is contacted too. Only
  # `succeeded` says the charge was approved. See docs/payment-demands.md,
  # "Lifecycle".
  #
  # ## This endpoint returns two different kinds of record
  #
  # `POST /v2/payment_demands` creates a **payment intent** unless the request
  # says `confirmed: true`, and the intent is serialized exactly like a payment
  # demand — same `type`, same route, same readers.
  # Nothing in the response announces which one you hold except
  # `processor_state`, whose two sets of values do not overlap. `#intent?` and
  # `#demand?` are that comparison, written down once.
  #
  # It matters because only a demand has been charged. An intent is a parked
  # request that has taken no money and holds no authorization.
  #
  # ## The two ways to charge
  #
  # **One step** — `confirmed: true` on create. The charge is queued
  # immediately and the record comes back `pending` — accepted, not yet sent.
  # This is what a checkout wants, and it is the only shape where a failure to
  # create and a failure to charge cannot be separated by a crash in between.
  #
  # **Two steps** — create without `confirmed`, then `#confirm`. Create
  # validates far less: an intent was accepted here with no billing address
  # and no `purchase_kind`, and `#confirm` then rejected it for both. Anything
  # missing surfaces at confirm time, not at create time.
  #
  # `#confirm` also retries a **failed** demand — the only demand state it
  # accepts — and that is the reason it can never be retried automatically:
  # replaying it charges again.
  #
  # ## What this class deliberately does not have
  #
  # **No `#capture` and no `#void`.** Not an omission — the API has no route
  # for either, `confirm` is not capture, and deferred capture is unsupported
  # today for PCI compliance reasons on a timeline measured in years. A method
  # that 404'd would read as a server fault rather than as a capability that
  # does not exist. See docs/payment-demands.md.
  #
  # **No refunded total and no `#refunded?`.** A refund — partial or full —
  # leaves the demand `succeeded`; the `refunded` state was retired and existing
  # rows migrated back to `succeeded`. The server tracks the refunded balance
  # internally to cap refunds, but serializes no total: `amount_refunded_cents`
  # is documented by the OpenAPI snapshot and served by nothing. Sum the
  # `succeeded` refunds from
  # `Edge::RefundDemand.list(filter: { "payment_demand.id" => id })` instead.
  # See `documented_only_attributes` and `Edge::RefundDemand`.
  #
  # **No automatic retries.** See `.create` below — this is the one worth
  # reading before writing a retry loop of your own.
  class PaymentDemand < Resource
    contract "payment_demands"

    # `PATCH /v2/payment_demands/{id}/confirm`.
    custom_action :confirm

    # `processor_state` values that belong to a payment demand — a record Edge
    # has accepted for processing. Not one that has necessarily reached the
    # processor: `pending` and `processing` are both set before it is contacted.
    DEMAND_STATES = %w[pending processing succeeded reversed failed disputed].freeze

    # ...and the ones that belong to a payment intent, which this endpoint also
    # returns. Disjoint from DEMAND_STATES, which is the only reason telling the
    # two apart is possible at all.
    INTENT_STATES = %w[incomplete ready confirmed canceled].freeze

    # Attributes `PATCH /v2/payment_demands/{id}` actually applies, on both a
    # demand and an intent: the charge, addendum and settings groups.
    # `fee_cents` is accepted there too and is deliberately absent — it is
    # server computed on create, and letting a caller set their own fee on
    # update is not something to enable on this evidence.
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
      # `payment_demands.idempotency_key` is documented as "a unique value that
      # prevents double charging"; on every shipped server it does not. Two
      # identical POSTs sharing one key produce two demands and two charges —
      # verified, not inferred. `contract/manifest.yml` records
      # `idempotent_writes: false` so `retriable:` cannot be set here, and
      # Transport refuses it a second time.
      #
      # TODO: when Edge fixes idempotency on payment demands — replaying a
      # matching request and answering a changed one with a 422 on
      # `idempotency_key` — re-run the two-POST check against a deployed
      # server, mark `payment_demands` `idempotent_writes: true` in
      # `contract/manifest.yml`, and `retriable: true` starts working with no
      # other change.
      # Until then: **send an idempotency key anyway** — it costs nothing and
      # it is what makes the eventual replay find your record — but do not
      # retry a create on a timeout. Read the demand back by
      # `purchase_reference` instead. See docs/payment-demands.md.
      def create(attributes = {}, **rest)
        reject_manual_capture!(merged_attributes(attributes, rest))
        super
      end

      # Updates a payment intent, or a payment demand that has **failed** — the
      # server refuses an update in any other demand state, so a succeeded or
      # pending demand cannot be edited at all.
      #
      # Accepts far less than `create` does. An update on either kind of record
      # applies the charge, addendum and settings groups and the relationship
      # ids, and nothing else — so the 3DS results, `capture_method` and
      # `idempotency_key` are all accepted by the endpoint and dropped without
      # comment. See UPDATABLE.
      def update(id, attributes = {}, **rest)
        written = writable_on_update!(merged_attributes(attributes, rest))
        reject_manual_capture!(written)
        super
      end

      private

      # `capture_method: "manual"` is accepted by the API and reaches the card
      # network as an authorization rather than an immediate charge. Nothing can
      # then capture or void it: the API has no route for either. The money sits
      # authorised against a cardholder's account until the processor expires
      # it, and no Edge API call can either take it or release it.
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
              "supported today (see README.md). Omit capture_method for an " \
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

      # `update` applies only these. Anything else the API declares is
      # accepted, answered 200, and silently discarded — the
      # failure `reject_readonly!` exists to prevent, which the resource-level
      # `writable` flag cannot express because it has no per-operation
      # dimension.
      #
      # The reserved keywords are not attributes and are left alone.
      def writable_on_update!(written)
        offered = written.keys - UPDATABLE - RESERVED
        return written if offered.empty?

        raise ArgumentError,
              "payment_demands.update does not accept #{offered.sort.join(", ")}. An update " \
              "applies only #{UPDATABLE.join(", ")} and the relationship ids; anything " \
              "else is answered 200 and discarded. Set them when the demand is created."
      end
    end

    # True when this record is a payment intent: created without
    # `confirmed: true`, charged nothing, holding no authorization.
    def intent? = INTENT_STATES.include?(processor_state)

    # True when this record is a payment demand — accepted by Edge for
    # processing, which is not the same as charged: a `pending` demand has not
    # been sent anywhere yet. False for an intent **and** for a state this
    # client does not know, which is the safe direction: a new state must not
    # be read as "this was charged".
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
    #
    # Give any poll a deadline. Edge has no sweeper for stuck demands, and one
    # left in `processing` after a processor timeout may still have been
    # charged — it is "unknown", not "not charged".
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
