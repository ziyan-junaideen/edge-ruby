# API-side findings to revisit

Raised by `edge-ruby` while building against a local instance. Nothing here is
a client bug; each is something the client currently works around, refuses, or
cannot offer. Full write-ups are in [`release-blockers.md`](release-blockers.md).

Status is from the spike on 2026-08-30, against
`api.tryedge.test:4001` on branch `edg-1498-implement-pagination-in-to-the-jsonapi-interface`,
with full-access sandbox and live tokens.

## Acknowledged, parked

| # | Finding | Note |
| --- | --- | --- |
| FU-15 | `beneficial_owners` is documented with six `financial_institutions` fields (`icon_url`, `login_url`, `logo_url`, `name`, `primary_colour`, `state`) | Confirmed as an API-side issue; not to be worked around in the client. |
| FU-18 | No capture, void, cancel or authorize operation exists | Deferred capture is **not supported today for PCI compliance reasons**. Planned, but timeline depends on business growth — plausibly more than a year out. The client will not ship `#capture` or `#void` until it exists. |

## Eight of thirty resources answer 403 to a full-access token

Reproduced with **both** the sandbox and live secret tokens, which are
full-access — so this is not permission scope. Every `/v1` metering resource is
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

- `Edge::Request#resource_name` matches only the first path segment
  (`lib/edge/request.rb:24`), so `POST /v2/payment_demands/:id/confirm` would
  resolve to `payment_demands` and inherit its `idempotent_writes: true`.
  Harmless today because no sub-resource action is implemented; **must be
  fixed before `confirm` ships in commit 10**, because `confirm` is a retry of
  a failed demand and not a replay.
- `contract/manifest.yml` records `idempotent_writes: true` for
  `payment_demands`, but the only replay lookup in the API is
  `replay_refund_demand/3` on the refund create path. Payment demand creation
  only *generates* a key when one is absent (`core/transactions.ex:350`). The
  flag is unproven for `payment_demands` and should be verified before commit
  10 relies on it.
- `Edge::PaymentMethod#last_four` redefines the reader generated from the
  contract, so loading the gem with warnings on prints
  `method redefined; discarding old last_four`. It exists only to carry
  documentation. Pre-existing, harmless, and worth resolving so that warnings
  stay signal.
- `Edge::Resource` generates a reader for every attribute the manifest records,
  including those marked `from: openapi-snapshot-only` — documented by Edge but
  never serialized. Honouring provenance when generating readers is worth doing
  before those resources ship.
