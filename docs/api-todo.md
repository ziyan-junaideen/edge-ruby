# API-side findings to revisit

Raised by `edge-ruby` while building against a local instance. Nothing here is
a client bug; each is something the client currently works around, refuses, or
cannot offer. Full write-ups are in [`release-blockers.md`](release-blockers.md).

Status is from the spike on 2026-08-30 and a second pass on 2026-09-01,
against `api.tryedge.test:4001` with full-access sandbox and live tokens. The
first ran on branch `edg-1498-implement-pagination-in-to-the-jsonapi-interface`,
the second on `qb-process-on-pd-success`.

## Acknowledged, parked

| # | Finding | Note |
| --- | --- | --- |
| FU-15 | `beneficial_owners` is documented with six `financial_institutions` fields (`icon_url`, `login_url`, `logo_url`, `name`, `primary_colour`, `state`) | Confirmed as an API-side issue; not to be worked around in the client. |
| FU-18 | No capture, void, cancel or authorize operation exists | Deferred capture is **not supported today for PCI compliance reasons**. Planned, but timeline depends on business growth — plausibly more than a year out. The client will not ship `#capture` or `#void` until it exists. |

## Eight of thirty resources answer 403 to a full-access token

Reproduced with **both** the sandbox and live secret tokens, which are
full-access — so this is not permission scope. **Partly answered by FU-22**:
four of the eight (`integrations`, `financial_institutions`,
`merchant_punitive_actions`, `processor_details`) are unfinished controllers
that would query the customers table if the authorisation check let them
through. Every `/v1` metering resource is
among them, which also answers FU-7 ("is `/v1` metering merchant-facing?"): not
reachable by a merchant token at all.

| Resource | Version |
| --- | --- |
| `financial_institutions` | v2 |
| `integrations` | v2 |
| `merchant_punitive_actions` | v2 |
| `processor_details` | v2 |
| `meters` | v1 |
| `meter_digests` | v1 |
| `meter_notifications` | v1 |
| `meter_rate_cards` | v1 |

These endpoints are untested upstream and may simply be broken. Until they
answer, the client cannot verify its contract for them, and
`spec/contract/live_spec.rb` records the set so that one starting to work shows
up as a failing example.

## Most urgent

**FU-22 — eleven controllers list customers instead of their own resource.**
`events`, `integrations`, `merchant_punitive_actions`, `corporate_officials`,
`financial_institutions`, `merchant_integrations`, `legal_addresses`,
`permissions`, `red_flags`, `processor_details` and `webhook_deliveries` all
call `Core.Consumer.list_customers_by/2` in their `index`, copied from
`customers_controller.ex` and never changed. Ten pass no schema prefix, so the
query resolves against `public` and raises — which is the only reason this is
an error rather than wrong data. `webhook_subscriptions` fails differently: its
index hands the renderer an unexecuted `Ecto.Query`.

**`integrations_controller` is the one to look at first** — it is the single
copy that passes `prefix: current_mode`, so its customers query executes.
Any principal passing `can?(:basic)` there gets customer rows (email, name,
phone, IP) rendered through the Integrations view. A merchant secret token is
refused at `can?`, so it is not reachable that way; worth confirming nothing
else is.

This also closes the "eight resources answer 403" question below: for four of
them it was never permission scope, it was an unfinished controller behind an
authorisation check that hid it.

Survives a full database reset, on both tokens. `webhook_subscriptions` and
`webhook_deliveries` are both in the list, so this is in the way of anyone
building on webhooks.

## Being fixed

**FU-20 — `payment_demands.idempotency_key` does not prevent double charging.**
On every shipped server the key is never cast on create, there is no replay
lookup, and no unique constraint fires; two identical POSTs sharing one key
produced two payment demands, both 201.

**The fix in the working tree works.** `create_or_replay_payment_demand/2` with
a per-merchant advisory lock, a lookup across demands and intents, and a
`(merchant_id, idempotency_key)` unique index — verified 2026-09-01 against the
instance running it: one key, two POSTs, **one record**, key echoed back. It is
uncommitted and undeployed, so `contract/manifest.yml` still records
`idempotent_writes: false`. When it ships, one line in
`contract/bin/extract_manifest.rb` turns client-side retries on.

Until then any integrator who reads the field description and writes a retry
loop against it will charge customers twice.

**FU-21 — attributes marked `readonly: true` are writable, and some are
required.** The flag only annotates the generated OpenAPI document; nothing on
the write path reads it. All seven `threeds_view_fields/1` attributes on
`payment_demands` are cast on create, and `payer_timezone` is *required* —
a field documented read-only that a create cannot succeed without. The client
had to stop deriving `writable: false` from the flag for those seven, or
`PaymentDemand.create` could not be called at all.

## Correctness

| # | Finding | Effect |
| --- | --- | --- |
| FU-16 | Any refund moves its demand to `refunded` regardless of amount; nothing tracks a refunded total | Partial refunds cannot be offered at all. A 100-cent refund closed a 10000-cent demand. |
| FU-17 | `refund_demands.amount_currency` is documented as a string and is `Ecto.Enum<[:USD]>` set via `put_change`, which does not cast | Sending the documented `"USD"` is a 500. Omitting it succeeds. |
| FU-13 | Null relationship linkage has no clause and 500s; to-many linkage is dispatched one id at a time to callbacks declared `when is_list(ids)` | The client refuses both rather than sending a request that becomes a 500. |
| FU-14 | `payment_methods.expiry_month`/`expiry_year`, `merchant_tokens.expiry` and `merchants.business_privacy_policy_url` are declared by their views and never serialized — no `from:` mapping to the real column | A stored card's expiry cannot be read at all. |

## Ergonomics

| # | Finding | Effect |
| --- | --- | --- |
| FU-19 | A failed create returns a batch of error objects whose `title` is identical and whose `detail` is absent | Ten `can't be blank` in one response. The pointer is the only distinguishing part. |
| — | `PATCH /v2/payment_demands/:id/confirm` answers **405** for a demand in a non-confirmable state | 405 is not in the documented status list, and it does not distinguish "wrong state" from "wrong method". |
| — | `GET /v2/payment_demands/:id` can return a **payment intent** rendered through the payment demands view | `payment_intents` has no route and no view; `find_payment_demand_by/4` falls back to it. A caller cannot tell which kind of record they hold. |

## Carried on the client side

Not for the API team — recorded here so it is not lost.

- `contract/manifest.yml` records `idempotent_writes: false` for
  `payment_demands` (FU-20), and the extractor does not list it, so
  regenerating cannot restore the claim. Revisit only once replay is merged
  **and deployed** — not when it merges.
- `Edge::PaymentMethod#last_four` redefines the reader generated from the
  contract, so loading the gem with warnings on prints
  `method redefined; discarding old last_four`. It exists only to carry
  documentation. Pre-existing, harmless, and worth resolving so that warnings
  stay signal.
- `Edge::PaymentDemand` refuses `capture_method: "manual"`, which the API
  accepts. It is the one place this client declines something the server
  allows, and it is because nothing can capture or void the authorization
  afterwards. Revisit if deferred capture ships.

**Done since 2026-08-30**

- `Edge::Request#resource_name` now stops at a member, so
  `PATCH /v2/payment_demands/:id/confirm` inherits no resource's
  `idempotent_writes`.
- `Edge::Resource` no longer generates a reader for an attribute marked
  `from: openapi-snapshot-only`. That covered `payment_demands`
  `amount_refunded_cents`, which would have shipped in commit 10 returning nil
  forever and reading as "nothing refunded yet".
