# frozen_string_literal: true

module Edge
  # Something that happened, which webhooks deliver and `/v2/events` lists.
  #
  # ## The event code is split across two attributes
  #
  # What documentation and dashboards call the event —
  # `transaction.payment_demands.succeeded` — is **not** in `slug`. The server
  # stores it in two columns (`developers.ex:168-181`):
  #
  #   resource_type  "transaction.payment_demands"
  #   slug           "succeeded"
  #
  # and joins them only as a local variable, to match subscriptions
  # (`record_event_and_deliver_webhooks/3`, `developers.ex:189`). Neither the
  # stored event nor the webhook delivery ever carries the joined form.
  #
  # `#code` is that join, and is what a handler should dispatch on — it is
  # also the form `WebhookSubscription#events` holds, so it is the only value
  # that can be compared against a subscription at all.
  #
  #     event.code           # => "transaction.payment_demands.succeeded"
  #     event.resource_type  # => "transaction.payment_demands"
  #     event.slug           # => "succeeded"
  #
  # ## A delivered event is not identical to a fetched one
  #
  # `Edge::Webhook` builds one from a delivery; `Edge::Event.retrieve` fetches
  # the stored record. The delivered form carries `mode`, `resource_type`,
  # `resource_id`, `slug` and `data` and **no `created_at`**
  # (`deliver_webhook_job.ex`, `event_resource/1`). `#id` is identity in both,
  # and is what to deduplicate on.
  class Event < Resource
    contract "events"

    # The full event code: `"transaction.payment_demands.succeeded"`.
    #
    # Nil when either half is missing, rather than a half-built string like
    # `"transaction.payment_demands."` that would silently fail to match any
    # subscription while looking plausible in a log.
    def code
      type = self[:resource_type].to_s
      name = self[:slug].to_s
      return nil if type.empty? || name.empty?

      "#{type}.#{name}"
    end

    # `"transaction"` or `"consumer"` — the first segment of `resource_type`,
    # for coarse routing. Match `#code` whole for anything finer: a
    # `start_with?("transaction.refund_demands.")` would also catch a
    # `transaction.refund_demands.disputed` that Edge adds next year and
    # nobody has written a handler for.
    def domain = self[:resource_type].to_s.split(".").first

    # The resource as it stood when the event fired — a JSON:API resource
    # object, not an Edge::Resource. **A snapshot, not the current state.**
    # Deliveries are retried and can arrive out of order, so anything that
    # matters should be re-fetched by `#resource_id` before acting.
    def data = self[:data]

    def live? = self[:mode] == "live"
    def sandbox? = self[:mode] == "sandbox"
  end
end
