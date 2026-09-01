# Webhooks

How to receive an Edge webhook without being lied to, and without processing
the same event twice.

## Verify before you parse

```ruby
post "/webhooks/edge" do
  event = Edge::Webhook.construct_event(
    request.body.read,                      # raw bytes, before any parser
    request.env["HTTP_EDGE_SIGNATURE"],
    ENV.fetch("EDGE_WEBHOOK_SECRET")        # the subscription's secret_key
  )

  ProcessEdgeEvent.perform_later(event.id, event.code)
  status 200
end
```

In Rails the raw body is `request.raw_post` and the header is
`request.headers["edge-signature"]`. **It has to be the raw bytes.** JSON key
order is not stable, so a Hash that has been parsed and re-encoded produces
different bytes and can never match the signature. `construct_event` refuses a
Hash outright rather than failing later in a way that looks like a bad key.

Rails also needs the route exempt from CSRF, and — if anything upstream
rewrites the body — the signature is computed over what Edge sent, not what
arrives after rewriting.

## What a valid signature proves

That the body was produced by someone holding the subscription's `secret_key`,
that it has not been altered, and that it was signed within the tolerance
window (five minutes by default).

**It does not prove the delivery is new.** This is the part that costs money.
Edge retries a failed delivery, and a delivery can be redelivered by hand.
Both carry a signature that verifies. Both are inside the window. The
timestamp bounds how long a captured delivery stays useful; it does not make
one single-use.

So: **deduplicate on `event.id`**, and make the handler idempotent.

```ruby
class ProcessEdgeEvent < ApplicationJob
  def perform(event_id, code)
    # A unique index on edge_event_id is what actually enforces this. The
    # check-then-insert without one loses to two deliveries arriving together.
    return if ProcessedEdgeEvent.exists?(edge_event_id: event_id)

    ProcessedEdgeEvent.create!(edge_event_id: event_id)
    handle(code)
  rescue ActiveRecord::RecordNotUnique
    nil # another worker got there first
  end
end
```

## Only v3 can be verified

A merchant's `webhook_delivery_version` decides the scheme.

| Version | Header | Worth |
| --- | --- | --- |
| **v3** | `edge-signature: t=<unix>,v3=<hex>` — HMAC-SHA256 over `"<timestamp>.<raw body>"`, keyed by `secret_key` | Integrity and freshness |
| v1, v2 | `x-hub-signature: Base64(SHA1(secret_key))` | **Nothing.** Constant for the life of the subscription; the body is not an input |

The legacy value is not a signature — the server's own comment says so. It
proves only that the sender once knew the secret, which is also true of anyone
who has ever seen one of its deliveries. This client implements **v3 only**,
deliberately: a `verify_v1` would be a method whose name promises something it
cannot do. Handing a v1/v2 header to `Edge::Webhook` raises an error that says
which version you are on rather than reporting a mismatch.

If you are on v1 or v2, treat a delivery as a **hint**: re-fetch the resource
by id over the API, and act on what you read there.

## The freshness window is a window

`tolerance:` defaults to 300 seconds and is checked in **both** directions, so
a receiver whose clock runs fast does not accept deliveries dated arbitrarily
far ahead.

```ruby
Edge::Webhook.construct_event(body, header, secret, tolerance: 600)
Edge::Webhook.construct_event(body, header, secret, tolerance: nil)  # no check at all
```

Before widening it, check the receiving server's clock — a persistent skew is
the usual cause, and widening the window hides it while making captured
deliveries useful for longer.

## The event, and where the event code actually lives

**`event.slug` is not the event code.** The server stores the code in two
columns and joins them only in passing, to match subscriptions
(`developers.ex:168-189`); neither the stored event nor the delivery ever
carries the joined form.

| | |
| --- | --- |
| `event.resource_type` | `"transaction.payment_demands"` |
| `event.slug` | `"succeeded"` |
| `event.code` | `"transaction.payment_demands.succeeded"` |

`#code` is the join, and it is what to dispatch on. It is also the form
`WebhookSubscription#events` holds, so it is the only value that can be
compared against a subscription at all — `subscription.subscribed_to?(event.slug)`
is false every time.

```ruby
event.id            # dedup on this
event.code          # "transaction.payment_demands.succeeded" — dispatch on this
event.resource_type # "transaction.payment_demands"
event.slug          # "succeeded"
event.domain        # "transaction"
event.resource_id   # the payment demand's id
event.data          # the resource as it stood when the event fired
event.live?         # or #sandbox?
```

```ruby
case event.code
when "transaction.payment_demands.succeeded" then fulfil(event.resource_id)
when "transaction.refund_demands.updated"    then reconcile(event.resource_id)
end
```

`event.data` is a **snapshot, not current state**. Deliveries are retried and
can arrive out of order, so anything that matters should be re-fetched by
`resource_id` before you act on it.

A delivered event carries no `created_at` — the delivery payload does not
include one (`deliver_webhook_job.ex`, `event_resource/1`). A fetched one does.
Order by your own receipt time, not by an attribute that is nil half the time.

## Event codes

The sixteen Edge documents (`views/webhook_subscriptions.ex:11-27`). These are
the strings a subscription's `events` array holds, and the strings `event.code`
produces.

```
transaction.payment_demands.{created,succeeded,failed,refunded,disputed}
transaction.refund_demands.{created,updated,failed}
transaction.payment_subscriptions.{created,updated}
consumer.customers.{created,updated}
consumer.addresses.{created,updated}
consumer.payment_methods.{created,updated}
```

Note the server's two lists disagree: `views/events.ex` omits the
`consumer.payment_methods` rows that `views/webhook_subscriptions.ex` includes.
The subscription list is the one that governs what you can subscribe to.

**A successful refund emits `transaction.refund_demands.updated`, not
`.succeeded`.** There is no `refund_demands.succeeded` event. Inspect
`data.attributes.state` for `succeeded` — and note that `errored` is a distinct
terminal state from `failed`, so a handler that waits for `failed` waits
forever.

Match codes whole. `start_with?("transaction.refund_demands.")` will also catch
a `transaction.refund_demands.disputed` that Edge adds next year and nobody has
written a handler for.

## Testing your handler

```ruby
header = Edge::Webhook.test_signature(body, secret)
post "/webhooks/edge", body, { "HTTP_EDGE_SIGNATURE" => header }
```

`test_signature` exists so your specs do not have to reimplement the signing
scheme and then drift from it. Pass `timestamp:` to build a stale delivery and
prove your rejection path works.

## Reading subscriptions and deliveries

`Edge::WebhookSubscription` and `Edge::WebhookDelivery` map the two endpoints.

`update` accepts only `concurrency_limit`, `description`, `events` and `url`.
The controller special-cases `status: "archived"` and otherwise **drops**
`status`, `archived_at` and the merchant before the changeset runs, and
`secret_key` is only ever set on create — so `update(id, status: "paused")` was
a `200` that changed nothing while deliveries kept flowing. The client refuses
it; **`WebhookSubscription.archive(id)`** is how deliveries are stopped, and
there is no unarchive.

`WebhookDelivery#failed_attempts` counts failures, not retries: a 400, 401,
403, 404 or 405 is never retried, so a delivery your endpoint 404'd has a count
of one and was tried exactly once.

**Both answer 500 today** — `webhook_subscriptions#index` hands its renderer an
unexecuted query, and `webhook_deliveries#index` lists customers instead. See
[FU-22](release-blockers.md#fu-22--eleven-controllers-list-customers-instead-of-their-own-resource).
The routes exist and this client builds the right requests; what comes back is
a server fault, surfaced as `Edge::ServerError`.

**Verification is unaffected** — it is entirely local and needs nothing but the
body, the header and the secret.

`secret_key` is readable on a subscription and redacted from every log line,
error message and `inspect` the client produces. `#raw` is the documented
exception.
