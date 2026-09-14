# edge-ruby

A Ruby client for the [Edge Payment Technologies](https://tryedge.io) HTTP API,
for Rails, Sinatra and plain Rack applications.

> **Unofficial.** This is an independent client, not published, supported or
> certified by Edge Payment Technologies, and not an official Edge release. It
> is written and maintained by [Ziyan Junaideen](#author) in Colombo, Sri
> Lanka. Bugs here are bugs here: report them on this repository, not to Edge
> support.

> **0.x.** The public API is still being settled and may change in any release
> until 1.0. What is here is exercised against sandbox rather than assumed —
> see [What the API cannot do](#what-the-api-cannot-do) for the gaps that
> constrain what this client is willing to expose.

## Installation

```ruby
gem "edge-ruby"
```

Requires Ruby >= 3.2. The only runtime dependency is Faraday 2.

## Quick start

```ruby
Edge.configure do |config|
  config.api_key = ENV.fetch("EDGE_SECRET_KEY")
end

customer = Edge::Customer.create(email: "ada@example.com", name: "Ada Lovelace")
customer.addresses.fetch          # relationships never fetch implicitly
```

`Edge.configure` sets one process-wide client. Anything holding several
merchants' credentials builds clients instead, and passes one per call:

```ruby
client = Edge::Client.new(api_key: merchant.edge_secret_key)
Edge::Customer.list(client: client, filter: { email: "ada@example.com" })
```

Charging a stored payment method, in one step:

```ruby
demand = Edge::PaymentDemand.create(
  {
    amount_cents: 5_00, amount_currency: "USD",
    purchase_kind: "order", purchase_reference: order.number,
    payer_timezone: "Europe/London", confirmed: true,
    idempotency_key: order.edge_idempotency_key
  }.merge(order.threeds_results),
  relationships: { payer: customer, payment_method: method_id, billing_address: address }
)

demand.demand?          # => true — an intent would be false, and has charged nothing
demand.processor_state  # => "pending" — accepted by Edge, not yet sent anywhere
```

**`pending` does not mean the card has been charged, or even that the charge
has reached the card networks.** It means Edge has stored the demand and queued
a background job. `processing` is set before the processor is contacted, too.
Only `succeeded` means the charge was approved, so fulfil on that, not on the
`201`. The same holds for refunds.

Without `confirmed: true` that same call creates a payment *intent*, which has
taken no money. Read [`docs/payment-demands.md`](docs/payment-demands.md) before
building a checkout on it.

Verifying a webhook, over the raw request body:

```ruby
event = Edge::Webhook.construct_event(
  request.body.read,                      # raw, before any parser touches it
  request.get_header("HTTP_EDGE_SIGNATURE"),
  ENV.fetch("EDGE_WEBHOOK_SECRET")
)
```

Only delivery version v3 can be verified at all; v1 and v2 send a constant
digest that does not cover the body. See [`docs/webhooks.md`](docs/webhooks.md).

## What is in this release

`Customer`, `ConsumerAddress`, `PaymentMethod`, `PaymentDemand`, `RefundDemand`,
`Event`, `WebhookSubscription` and `WebhookDelivery`, plus webhook signature
verification, operation-aware retries, redaction, and typed errors.

Subscriptions, merchant-facing account resources and `/v1` metering are not
here yet. `client.get` / `client.post` / `client.patch` reach any endpoint in
the meantime and are a supported escape hatch, not a workaround. How Edge's
subscriptions behave, and the open questions that are holding back an
`Edge::PaymentSubscription` class, are in
[`docs/payment-subscriptions.md`](docs/payment-subscriptions.md).

## Documentation

| | |
| --- | --- |
| [`docs/payment-demands.md`](docs/payment-demands.md) | Intents vs demands, charging in one or two steps, what each `processor_state` means, and what cannot be done |
| [`docs/refund-demands.md`](docs/refund-demands.md) | The refund lifecycle, when a refund is really issued, and its events |
| [`docs/payment-subscriptions.md`](docs/payment-subscriptions.md) | How recurring billing works, failed-charge retries, and its gaps |
| [`docs/webhooks.md`](docs/webhooks.md) | Verifying deliveries, deduplicating, and dispatching on event codes |
| [`docs/pagination.md`](docs/pagination.md) | Why collections come back whole |
| [`docs/local-development.md`](docs/local-development.md) | Pointing the client at another host, private CAs, and the live contract checks |

## Naming

The gem is `edge-ruby`; the namespace is `Edge`.

`edge` is taken on RubyGems by an unrelated ActiveRecord graph library, so the
repository name doubles as the package name — the same shape as `stripe-ruby`.

`Edge` is a broad top-level constant and can collide with an application's own
`Edge` model. That is an accepted tradeoff, recorded here so it is a choice
rather than a surprise. The gem ships both `lib/edge.rb` and a
`lib/edge-ruby.rb` shim, so `gem "edge-ruby"` works without a `require:` option.

## Design commitments

Settled decisions that constrain the implementation, and that the resources in
this release are built on.

- **Stripe-shaped objects.** Attributes are methods, relationships are
  accessors, and the untouched JSON:API document is always reachable via `#raw`.
- **Instance client first.** `Edge::Client.new` is the real object;
  `Edge.configure` sets a default one for the common case. Multi-merchant
  applications and background jobs pass a client explicitly.
- **No hidden network I/O.** A relationship that was not `include:`d returns an
  identifier with an explicit `#fetch`. Getters never make requests, so
  serializers and views cannot produce accidental N+1s.
- **Forward-compatible parsing.** Unknown attributes stay reachable and unknown
  enum values are preserved. The server has already shipped fields our contract
  does not know about; parsing must not break when that happens again.
- **Writes are explicit.** No generic dirty tracking, no `#save`. The API's
  documentation does not say which attributes are writable per operation, so
  the client states it per operation rather than inferring it.
- **Reads retry; writes do not.** A write opts into retries only after its
  server-side replay contract has been exercised against sandbox.
- **Idempotency keys are yours.** The client does not mint ephemeral ones: a key
  generated inside a call cannot protect a job retried in another process.
- **Secrets are redacted by default.** The API returns webhook signing keys,
  merchant tokens and KYC identifiers. None of them appear in `inspect`,
  exception messages, logs or instrumentation. Request and response bodies are
  not logged.

## What the API cannot do

Worth knowing before designing against it.

- **No capture and no void.** `PATCH .../confirm` means "ready for processing",
  not capture — on a demand it only accepts a *failed* one, as a retry. No route
  captures or voids, and deferred capture is not supported today. This client
  will not fake them.
- **The idempotency key on a payment demand does not prevent a double charge.**
  Its own description says it does. Two identical requests sharing one key
  produced two demands and two charges, so `retriable:` is refused there —
  send a key anyway, but do not retry a create. Edge is working on a fix; see
  [`docs/payment-demands.md`](docs/payment-demands.md#the-idempotency-key-does-not-prevent-a-double-charge).
- **Creating a payment demand usually needs the browser.** With 3D Secure on —
  the default — six required attributes are results of a handshake the browser
  performs, so a background job cannot build one from order data alone. Whether
  it is on is a per-merchant, per-card-kind setting the API does not report.
- **`POST /v2/payment_demands` creates a payment *intent*** unless the request
  says `confirmed: true`, and returns it looking exactly like a payment demand.
  Only a demand has been charged. See
  [`docs/payment-demands.md`](docs/payment-demands.md).
- **A webhook signature proves integrity, not novelty.** Retries and manual
  redeliveries both verify. Deduplicate on the event id; see
  [`docs/webhooks.md`](docs/webhooks.md). Only delivery version v3 can be
  verified at all — v1 and v2 send a constant digest that does not cover the
  body.
- **`pending` and `processing` are not "sent", and nothing unsticks them.**
  For payments and refunds alike, both states are set before the payment
  processor is contacted. `succeeded` means the card network approved the charge
  or refund, not that it settled. Edge does not time out stuck records, so one
  can stay `processing` after a timeout even though it was charged. Treat it as
  unknown. See
  [`docs/payment-demands.md`](docs/payment-demands.md#lifecycle-what-each-state-actually-means).
- **Partial refunds work, but no refunded total is served.** A payment demand
  can be refunded several times up to its amount, and the server enforces the
  cap. The demand stays `succeeded` throughout and carries no refunded amount;
  list its refund demands to find out what has been refunded. See
  [`docs/refund-demands.md`](docs/refund-demands.md).
- **Subscriptions cannot be cancelled or paused over the API**, and doing either
  in the dashboard sends no webhook. See
  [`docs/payment-subscriptions.md`](docs/payment-subscriptions.md).
- **`GET /v2/financial_institutions` returns the wrong `data.type`.**
- **Collections are not paginated.** Every record comes back in one response,
  and this is not expected to change soon. See
  [`docs/pagination.md`](docs/pagination.md).
- **Hosts with a private CA need `ssl:`.** Ruby does not read the macOS
  keychain, so an mkcert certificate every other tool trusts is rejected. See
  [`docs/local-development.md`](docs/local-development.md).

## The contract directory

`contract/manifest.yml` is what this client is built against, and it comes
first because everything else depends on it: operations, relationships,
writeability, enums, sensitive fields and redaction rules for every resource.
Each attribute records where it is known from — what the server serves, or only
what Edge documents (`from: openapi-snapshot-only`).

It is maintained from observed API behaviour, and the parts that shape
requests are checked against sandbox by `spec/contract/live_spec.rb` (see
[`docs/local-development.md`](docs/local-development.md#running-the-contract-checks)).
Enum values are a lower bound: the client accepts values the manifest does not
list.

## Author

Written and maintained by **Ziyan Junaideen**, Colombo, Sri Lanka. This is a
personal project, not affiliated with or endorsed by Edge Payment
Technologies.

- X: [@ZiyanJunaideen](https://x.com/ZiyanJunaideen) (preferred)
- Email: [ziyan@jdeen.com](mailto:ziyan@jdeen.com)

## License

MIT. See [`LICENSE`](LICENSE).
