# frozen_string_literal: true

module Edge
  # Where Edge sends events: `/v2/webhook_subscriptions`.
  #
  # `secret_key` is the key every delivery to this subscription is signed with.
  # It is readable here and redacted from every log line, error message and
  # `inspect` the client produces; `#raw` is the documented exception.
  #
  # **`GET /v2/webhook_subscriptions` answers 500 today** — the index hands its
  # renderer an unexecuted query. The route exists and this client builds the
  # right request; what comes back is a server fault. See
  # docs/release-blockers.md, FU-22.
  class WebhookSubscription < Resource
    contract "webhook_subscriptions"

    # What `update_changeset/2` actually casts (`webhook_subscription.ex:55`),
    # minus `merchant_id` and `mode`, which the controller drops before the
    # changeset sees them.
    UPDATABLE = %w[concurrency_limit description events url].freeze

    # Keywords `update` consumes, which are never attributes.
    RESERVED = %w[client relationships retriable].freeze

    class << self
      # Updates a subscription. Accepts much less than the manifest suggests:
      # the controller special-cases `status: "archived"` and otherwise drops
      # `status`, `archived_at`, `merchant` and `merchant_id` outright
      # (`webhook_subscriptions_controller.ex:198-206`), while `secret_key` is
      # only ever set on create.
      #
      # So `update(id, status: "paused")` was a 200 that changed nothing and
      # left deliveries flowing at a merchant who believed they had stopped.
      # That one is refused by name; `#archive` is the supported operation.
      def update(id, attributes = {}, **rest)
        reject_undroppable!(stringify(attributes).merge(stringify(rest)))
        super
      end

      # Archives the subscription, which is the only status change the API
      # honours. There is no unarchive.
      #
      # Builds the request from the same primitives `update` does rather than
      # calling it with a flag that turns the guard off — a bypass keyword
      # would also be forwarded into the body and sent as an attribute called
      # `skip_guard`, which the server would drop without comment.
      def archive(id, client: nil)
        client = client_for(client)
        body = body_for({ "status" => "archived" }, nil, id: id)
        single(client.patch(member_path(id), body: body), client)
      end

      private

      def reject_undroppable!(written)
        offered = written.keys - UPDATABLE - RESERVED
        return if offered.empty?

        raise ArgumentError,
              "webhook_subscriptions.update does not accept #{offered.sort.join(", ")}. The " \
              "controller drops status, archived_at and the merchant before the changeset runs, " \
              "and secret_key is only set on create — so the request is answered 200 and " \
              "changes nothing. Use .archive(id) to stop deliveries."
      end
    end

    def active? = self[:status] == "active"

    def archived? = !self[:archived_at].nil?

    # Event codes this subscription asked for —
    # `"transaction.payment_demands.succeeded"`, the joined form. Always an
    # array.
    def events = self[:events] || []

    # Whether this subscription asked for that event. Takes an `Edge::Event`
    # or a code string.
    #
    #     subscription.subscribed_to?(event)
    #     subscription.subscribed_to?("transaction.payment_demands.succeeded")
    #
    # An Event is read through `#code`, never `#slug`: the slug is only the
    # last segment (`"succeeded"`), so comparing it against this list would be
    # false every time. Matching is exact — a prefix match would claim a
    # future `transaction.refund_demands.disputed` was subscribed.
    def subscribed_to?(event)
      code = event.is_a?(Event) ? event.code : event.to_s
      !code.nil? && events.include?(code)
    end
  end
end
