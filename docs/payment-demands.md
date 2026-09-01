# Payment demands

What `Edge::PaymentDemand` can do, what it deliberately cannot, and the two
things that will bite an integrator who reads the API documentation alone.

Everything here was verified against a running instance on 2026-09-01, not read
off the OpenAPI document. Where the two disagree, this file says so.

## One endpoint, two kinds of record

`POST /v2/payment_demands` creates a **payment intent** unless the request
carries `confirmed: true`. The intent comes back rendered through the payment
demand view — same `type`, same route, same readers — and nothing in the
response says which kind you are holding except `processor_state`:

| Kind | `processor_state` |
| --- | --- |
| Payment **intent** — nothing charged, no authorization held | `incomplete`, `ready`, `confirmed`, `canceled` |
| Payment **demand** — sent to the processor | `pending`, `processing`, `succeeded`, `reversed`, `refunded`, `failed`, `disputed` |

The two sets are disjoint, which is the only reason telling them apart is
possible. `#intent?` and `#demand?` are that comparison written down once, and
both answer `false` for a state this client does not know — so a state added
server-side can never be read as "this was charged".

```ruby
demand.intent?        # true  => no money moved
demand.demand?        # true  => it reached the processor
demand.state_known?   # false => neither; go and look
```

## Charging in one step

What a checkout wants. The charge is enqueued during the request and the record
comes back `pending`.

```ruby
demand = Edge::PaymentDemand.create(
  {
    amount_cents: 5_00,
    amount_currency: "USD",
    purchase_kind: "order",
    purchase_reference: order.number,
    payer_timezone: "Europe/London",
    idempotency_key: order.edge_idempotency_key,
    confirmed: true,
    # produced by the browser 3DS handshake — see below
    eci: results.eci,
    threeds_status: results.status,
    threeds_version: results.version,
    directory_transaction_eid: results.directory_transaction_id,
    acs_transaction_eid: results.acs_transaction_id
  },
  relationships: {
    payer: customer,
    payment_method: payment_method_id,
    billing_address: address
  }
)

demand.processor_state   # => "pending"
demand.in_flight?        # => true
```

`amount_currency` is required and must be `"USD"`, the only currency the schema
has. (On **refunds** the same field 500s when sent — see FU-17. They are not
symmetrical.)

`update` accepts much less than `create`. `PATCH /v2/payment_demands/{id}`
casts the charge, addendum and settings groups and the relationship ids, and
nothing else — the 3DS results, `capture_method` and `idempotency_key` are all
accepted, answered `200`, and discarded. The client refuses them rather than
letting a caller believe a field changed. A demand can only be updated at all
while it is `failed`.

## Charging in two steps

Create without `confirmed`, then confirm. This is worth knowing about mainly so
its trap is visible: **create validates far less than confirm does.**

```ruby
intent = Edge::PaymentDemand.create(amount_cents: 5_00, amount_currency: "USD", …)
intent.intent?           # => true, processor_state "incomplete"

demand = intent.confirm  # => a new object, same id, processor_state "pending"
```

An intent was accepted here with no billing address and no `purchase_kind`, and
`#confirm` then rejected it for both. Anything missing surfaces at confirm time.
`#confirm` returns a **new** object; the receiver still reports the state it was
parsed with.

`confirm` answers **405** rather than 422 when the record is in a state it
cannot confirm, which is not in the documented status list and does not
distinguish "wrong state" from "wrong method".

## `confirm` is also a retry, and is never retriable

The other half of `confirm`'s guard (`is_confirmable_demand`,
`payment.ex:26`) matches a demand in `failed` — confirming one **charges
again**. That is why the client refuses `retriable: true` on the action's path
at all: `Request#resource_name` stops at a member, so a sub-resource inherits no
resource's replay contract and `Transport` rejects the request before it is
sent.

## The idempotency key does not prevent a double charge

The field's own description reads *"a unique value that prevents double
charging"*. On every shipped server it does not. Two byte-identical POSTs
sharing one key produced **two payment demands, both `201`** — the key is not
cast on create, no replay lookup runs, and no unique index fires. Full write-up:
[FU-20](release-blockers.md#fu-20--payment_demandsidempotency_key-does-not-prevent-double-charging).

So:

- `contract/manifest.yml` records `idempotent_writes: false`, and
  `retriable: true` is refused on `PaymentDemand.create`.
- **Send an idempotency key anyway.** It costs nothing, and it is what the
  eventual replay will find your record by.
- **Do not retry a create on a timeout.** Read the demand back by
  `purchase_reference` — which you control and which is filterable — and decide
  from what you find.

A fix is written, works, and is unmerged. When it deploys, one line in
`contract/bin/extract_manifest.rb` turns retries on.

## Creating a demand usually needs the browser

When 3D Secure is on, six attributes are required — `eci`, `threeds_status`,
`threeds_version`, `threeds_cryptogram`, `directory_transaction_eid`,
`acs_transaction_eid` — and every one is a result of a handshake the browser
performs. A server-side job cannot invent them, so a Solidus or Spree gateway
cannot build the request from order data alone: the 3DS results have to be
captured at checkout and carried through.

**Whether 3DS is on is not a property of the API.** `create_changeset/3`
branches on `Core.Transactions.threeds_enabled?/2`
(`core/transactions.ex:285-290`), which is
`:threeds in processor_detail.network_featureset[payment_method.kind]` — per
processor, per card kind. With it off, `threeds_skip_changeset/1` sets
`threeds_skipped: true` and requires none of the six. So a purely server-side
create *is* possible for a merchant whose processor has 3DS disabled for that
card kind, and impossible otherwise, and the client cannot tell which you are
from anything in the response.

Note that the fallback clause returns `true` when the processor detail or
payment method is nil, so **3DS-required is the default**. Assume you need the
browser unless you have checked your own processor's featureset.

`payer_timezone` is required either way.

All seven of these are documented `readonly: true`. They are not — see
[FU-21](release-blockers.md#fu-21--attributes-marked-readonly-true-are-writable-and-some-are-required).

## What this class does not have, and why

| Missing | Why |
| --- | --- |
| `#capture` | No route exists. `confirm` is not capture. Deferred capture is unsupported today for PCI compliance reasons, planned on a timeline that may exceed a year. RB-1, FU-18. |
| `#void` | No route exists. A refund is not a void; presenting one as the other would promise a distinction the API cannot express. |
| `#amount_refunded` | `amount_refunded_cents` is documented by Edge and served by nothing. No shipped server tracks a cumulative refund total. RB-2. |
| partial refunds | Any refund of any amount moves the demand to `refunded` and no second refund is possible. A 100-cent refund closed a 10,000-cent demand. FU-16. |
| `capture_method: "manual"` | Accepted by the API, reaches the processor as an `auth`, and then **nothing can capture or void it**. It sits authorised against the cardholder's account until the processor expires it. The client refuses it. |

The last one is the only place this client declines something the server would
accept, and it is because "the server accepted it" is exactly what makes the
outcome invisible. `client.post("v2/payment_demands", body: …)` still sends
whatever you like.

## Reading a demand

```ruby
demand.succeeded?            # terminal states, tolerant of unknown ones
demand.failed?
demand.refunded?             # means "refunded", never "refunded in full"
demand.in_flight?            # pending or processing — worth polling
demand.line_items            # array of hashes, or []
demand.verification_passed?  # AVS and CVC both matched; false when unchecked
```

There is deliberately no `#confirmed?`. `#confirmed` is the boolean attribute
the create request carried, and a predicate one character away meaning the
intent's `processor_state` instead is a bug waiting to be written — compare
`processor_state == "confirmed"` for that. The attribute is unreliable in any
case: a demand created with `confirmed: true` came back with `confirmed` **nil**.

## Collections are not paginated

`Edge::PaymentDemand.list` returns **every** matching record in one response.
There is no `page[…]` support on any shipped server and no `links.next`. Filter
aggressively — `purchase_reference`, `created_at_gte` — and see
[pagination.md](pagination.md).
