# Release blockers and API-side follow-ups

Findings that constrain what this client may honestly expose. Each was verified
against the Edge source at `83641f3d887e02e021805e97d2fe78a54d5825d3`
(branch `edg-1498-implement-pagination-in-to-the-jsonapi-interface`), with
`main` at `8372ac06c76b5273ec36c365079759fdaa83010e`.

Blockers gate a release. Follow-ups are for the API team.

---

## RB-1 — There is no capture and no void (blocker)

**Blocks:** the Solidus and Spree gateways. Does not block the client's core.

`PATCH /v2/payment_demands/{id}/confirm` means "ready for processing". Its
guards are in `ept/lib/core/transactions/payment.ex:22-28`:

```elixir
defguard is_confirmable_intent(payment_intent)
         when is_struct(payment_intent, Core.Transactions.PaymentIntent) and
                payment_intent.processor_state in [:incomplete, :ready]

defguard is_confirmable_demand(payment_demand)
         when is_struct(payment_demand, Core.Transactions.PaymentDemand) and
                payment_demand.processor_state in [:failed]
```

A demand is confirmable only when it has **failed** — that path is retry. A
succeeded manual-capture authorization matches neither guard. **`confirm` is not
capture.**

There is no capture or void route in the router or in the snapshot. The
processor layer can do both:

- `ept/lib/core/remote_client/nmi.ex:127-128` — `capture_method: :manual` is
  sent to NMI as `"auth"` rather than `"sale"`, so authorizations really are
  created.
- `ept/lib/core/remote_client/nmi.ex:238` — `capture_transaction/1`, NMI
  `"type" => "capture"`.
- `ept/lib/core/remote_client/nmi.ex:271` — `cancel_transaction/1`, NMI
  `"type" => "void"`.

**Neither function has a caller anywhere in the tree.** There is no
orchestration and no HTTP surface. Authorize -> capture -> void is not reachable
end to end, and a `capture_method: :manual` demand strands its authorization.

### What the client does

- No `#capture`. It will not alias `confirm`, which would silently do the wrong
  thing.
- No `#void`. A refund is not a void. A gateway may choose that translation as
  documented store policy; this client will not make the choice on its behalf.
- Ship what the API supports, document the gap.

### Asked of the API

Expose capture and void, **or** reject `capture_method: :manual` at the edge so
authorizations are not created that nothing can settle or release.

---

## RB-2 — Refunds are not checked against a remaining balance (blocker)

**Blocks:** any partial-refund flow, which means the Solidus and Spree gateways.

On `main`, `ept/lib/core/transactions/refund_demand.ex:75-102`:

- `amount_cents` defaults to the **full** payment demand amount when omitted.
- Eligibility is `validate_can_be_refunded/1` (line 149), which requires
  `processor_state: :succeeded` and a refundable authorization.
- `Core.Transactions.find_refundable_authorization/1`
  (`ept/lib/core/transactions.ex:1325`) matches a `:completed` authorization for
  the **full** amount. It does not consider how much has already been refunded.

There is no cumulative check and no `amount_refunded_cents` on the server. A
merchant can issue several refunds against one payment demand, each up to the
full amount.

The balance tracking described in `contract/openapi.json` — "a payment demand
may be refunded more than once, so long as the refunds together do not exceed
its total", in-flight refunds reserving their amount — exists only on the
unmerged `backup/edg-4035-partial-refunds-wip-20260819` branch. See
`contract/PROVENANCE.md`.

### What the client does

- Does not expose `amount_refunded_cents`; it does not exist.
- Does not compute or imply a refundable balance.
- Documents that callers must track refunded totals themselves, and that the
  server will not stop an over-refund.

### Asked of the API

Enforce the cumulative balance server-side. A client-side guard is not a
substitute: two concurrent refunds would both pass it.

---

## RB-3 — `financial_institutions` reports the wrong JSON:API type (blocker)

`ept/lib/core_http/views/financial_institutions.ex:12`:

```elixir
def type(), do: "beneficial_owners"
```

So `GET /v2/financial_institutions` returns objects whose `data.type` is
`beneficial_owners`. The spec generator emits no `financial_institutions_*`
schema at all; all four paths share `beneficial_owners_collection` / `_member`.

The collision resolved in favour of the financial institution:
`beneficial_owners_member` holds `icon_url`, `login_url`, `logo_url`, `name`,
`primary_colour`, `state` (plus timestamps) and has no `ownership_percentage`.
So the *published docs for `/v2/beneficial_owners` describe the wrong resource*,
while `/v2/financial_institutions` gets the right fields under a misleading
name. Both endpoints are affected; the beneficial-owner one is worse.

### What the client does

A `data.type` -> class registry cannot be the sole means of identifying a
response. The requested route disambiguates, and `financial_institutions`
carries an explicit note until this is fixed. Deserialising by type alone would
hand back a `BeneficialOwner` populated with financial-institution fields.

### Asked of the API

One-character fix. Note it is technically a breaking change for anyone who
already keys off the wrong type.

---

## RB-4 — Auth failures are plain text, not JSON:API (blocker for error handling)

`ept/lib/core_http/plugs/http_authorization_plug.ex:30-50` responds with
`Plug.Conn.send_resp/3` carrying a bare reason phrase:

| Condition | Status | Body |
| --- | --- | --- |
| `{:error, :bad_value}` | 422 | `Unprocessable Content` |
| `{:error, :empty \| :not_found}` | 401 | `Unauthorized` |
| no token | 401 | `Unauthorized` |

Note the first row: a **malformed** `Authorization` header returns 422, not 401.
This client maps 422 to `Edge::InvalidRequestError`, so a broken credential
surfaces as a validation error rather than an authentication one. Nothing the
client can fix — the status is the only signal it has.

No JSON, no `application/vnd.api+json`. Every other error path returns JSON:API
error objects.

### What the client does

Never assumes a JSON body. Every exception retains status, headers and raw
body. A plain-text 401 or 422 must produce a useful typed exception, never a
`JSON::ParserError`.

### Asked of the API

Return JSON:API error documents here, consistently with every other error.

---

## FU-1 — The OpenAPI document describes no request bodies

Every write operation in the snapshot carries `requestBody: null`. Request
shapes had to be inferred from `ept/test/core_http/controllers/*_test.exs`.

This is the reason `contract/manifest.yml` is hand-derived and the drift check
cannot validate write coverage. Documenting request bodies would make the whole
contract process meaningfully stronger.

## FU-2 — Invalid filters are silently dropped

Rather than rejected. On today's unpaginated production this turns one typo into
a full-collection fetch. Server-side validation would be far better than
client-side guessing. See `docs/pagination.md`.

Sorts and includes behave differently again, and worse: see FU-10.

## FU-3 — The OpenAPI artifact is untracked and unreproducible

`ept/openapi.json` is gitignored by the monorepo root `.gitignore:8` and has
never been committed, so no consumer can tell which tree it came from. Ours came
from an abandoned WIP branch and documents a field no server has. Publishing a
spec per release, or committing it, would prevent that.

## FU-4 — No rate limiting is documented

The snapshot documents no 429 and no rate-limit headers. If a limiter sits in
front of production, its headers should be specified so clients can honour them
rather than treating a 429 as an opaque failure.

## FU-5 — Legacy webhook signing offers no integrity

`ept/lib/core/job/deliver_webhook_job.ex:66-72` — merchants on delivery version
v1/v2 get `x-hub-signature: Base64(SHA1(secret_key))`, constant per subscription
and not a function of the body. The server's own comment says it is "not a
signature in any meaningful sense".

This client verifies v3 only and will not present the legacy header as
verification. Is the delivery version readable from a `WebhookSubscription`, so
a client can tell a merchant to upgrade rather than silently failing?

## FU-6 — Confirm the API key prefixes

`contract/manifest.yml` resolves `merchant_tokens.context` to `browser` and
`secret`, and `merchant_tokens.schema` to the mode. The Elixir SDK's README
shows `ept_sandbox_…`. Confirm the exact live, sandbox and browser prefixes so
the client can reject a publishable key server-side with a useful error, and
expose `mode` only for recognised prefixes rather than guessing.

## FU-7 — Is `/v1` metering merchant-facing?

`meters`, `meter_ticks`, `meter_rate_cards`, `meter_notifications` and
`meter_digests` are the only `/v1` paths. If they are internal, they should not
enter this client's public surface at 1.0.

## FU-8 — `processor_details` serializes an attribute named `type`

`ept/lib/core_http/views/processor_details.ex:15` lists `type:` among `fields()`,
so the serialized resource object carries both a top-level `"type":
"processor_details"` and an `attributes.type` holding the enum value.

JSON:API 1.1 §5.2 forbids exactly this: "a resource object's attributes and its
relationships are collectively called its *fields* [and] a resource can not have
an attribute or relationship named `type` or `id`." The reason is the collision
every client then has to work around.

### What the client does

`Edge::Resource#type` is the JSON:API type, as it must be everywhere else; the
attribute is read as `detail["type"]` and is listed in
`ProcessorDetail.shadowed_attributes`. `#to_h` returns the attributes without
folding identity over them, so the value is not destroyed. A spec pins the set
of shadowed names across the whole manifest, so a second collision fails the
build rather than silently returning the wrong thing.

### Asked of the API

Rename the field — `processor_type`, or `kind`. Breaking, but it is already
breaking every spec-compliant client.

## FU-9a — A relationship can only be filtered when it is a belongs-to

`relationship_filter/5` (`parameters.ex:406-427`) resolves the association and
matches only `Ecto.Association.BelongsTo`; every other kind falls through to
`_association -> :error` at `:425`. So `filter[payment_demands]=<id>` on a
merchant — and `filter[payment_demands.id]`, which takes the same path
(`:382`) — is dropped, returning every merchant.

Seventeen relationships across the manifest are to-many. The client refuses
these in strict mode, using the cardinality the manifest records. It cannot
catch a `has_one`, which is cardinality one but still not a belongs-to.

Filtering the collection the other way round works, so this is a documentation
gap as much as a behavioural one — but a dropped filter over an unpaginated
collection is not a good way to discover it.

## FU-9 — Comparison operators are unreachable across relationships

`ept/lib/phoenix_jsonapi/filters.ex:107-124` implements `gt`/`lt`/`gte`/`lte`
for `:relationship_attribute` filters, joining the chain and comparing on the
related record.

Nothing can reach it. `parameters.ex:272` only strips a comparison suffix from a
**single-segment** key; `extract_operator/1` returns `{:ok, :eq, path}` for
anything longer. So `filter[merchant.created_at_gte]` is parsed as equality on a
field named `created_at_gte`, which does not exist, and the filter is dropped —
returning the whole collection rather than an error.

The client raises on this shape rather than sending it. Either extend
`extract_operator/1` to the last segment of a path, or delete the dead clauses
so the next reader does not assume the feature works.

## FU-10 — An unknown `sort` or `include` field fails non-deterministically

`jsonapi_parser_plug.ex:129` and `:153` convert every `include`, `sort` and
`fields` segment with `String.to_existing_atom/1` and no rescue, before
`normalized_sorts/4` gets the chance to drop unknown names.

So the outcome depends on whether the mistyped word happens to exist as an atom
anywhere in the running VM: if it does, the filter is silently dropped; if it
does not, the plug raises `ArgumentError`. Same request, different behaviour on
different deploys.

Rescuing at the plug boundary would at least make it consistently silent, and
returning a JSON:API error would be better than either.

## FU-11 — A to-many relationship carries no resource linkage, ever

`ept/lib/phoenix_jsonapi/resource.ex:130-136` builds every to-many relationship
as links only:

```elixir
{:many, _relationship} ->
  Map.put(aggregate, name, %PhoenixJSONAPI.Relationship{
    links: %{self: URI.to_string(URI.append_path(uri, "/#{record.id}/relationships/#{name}"))}
  })
```

There is no `data` member, and asking for the records with `include=` does not
add one — the includes change what lands in the document's `included` array, not
what the relationship object says.

JSON:API calls this **full linkage** and requires it: every resource in
`included` must be identified by at least one resource identifier object
elsewhere in the same document. Without it, a client receiving
`GET /v2/customers?include=addresses` gets a pile of addresses and no way to
tell which customer each belongs to. Matching by type would give every customer
every address.

The same clause covers two more cases at `:173-181`, where the `data` member is
commented out in the source: a belongs-to whose foreign key is null, and a
has-one. So an **unset** to-one and an **unlinked** to-one are the same bytes,
and JSON:API's distinction between `"data": null` and an absent `data` member is
unavailable.

### What the client does

`Relationship#loaded?` reports whether linkage arrived, and is false for every
to-many. `#resource` resolves from `included` for a to-one only. `#fetch` is the
answer for everything else, and is spelled as the request it makes. The client
does not guess.

### Asked of the API

Emit `data` for to-many relationships, at least when the relationship is
included; and emit `"data": null` for an unset to-one, so that "no payer" and
"not told" stop being the same response.

## FU-12 — A relationship link returns the resource, not the linkage

`ept/lib/phoenix_jsonapi/routing.ex:96-108` mounts
`GET /v2/<route>/:id/relationships/<name>` and renders it with the ordinary
`:show` or `:index` template. `test/core_http/controllers/consumer_addresses_controller_test.exs:196-211`
asserts the result: a full resource object, with `attributes`, `relationships`
and `links`.

JSON:API distinguishes two links here. A relationship's `self` link must return
**resource linkage** — identifier objects. The full record is what the `related`
link returns. Edge advertises the URL as `self` and returns the `related`
payload, and emits no `related` link at all.

Convenient in practice — one request gets the whole record — but a generic
JSON:API client that follows `self` expecting identifiers will misparse it. The
Ruby client reads the shape from the response rather than the link name, so it
works either way.

## FU-13 — Relationship writes: null linkage 500s, and to-many dispatch is broken

Two separate faults on the write path, both reached from a well-formed
JSON:API request.

**Unsetting a to-one is unimplemented.** `ept/lib/phoenix_jsonapi/conn.ex:256`
carries its own note:

```elixir
# TODO: Handle `%{"data" => null}`
defp fetch_relationship({key, %{"data" => %{"id" => id}}}, query, view)
```

The clauses cover a map with a binary `id` and a list. `nil` matches neither,
so `{"data": null}` — JSON:API's spelling of "this relationship is now empty" —
raises `FunctionClauseError` and returns 500. `must_properties_plug.ex:108`
waves it through first, so nothing rejects it politely.

**To-many linkage is dispatched one id at a time to callbacks that expect a
list.** `conn.ex:268-287` handles `%{"data" => [...]}` by calling
`query.(key, related_view, id)` once per element, with a **binary** id. But
`customers_controller.ex:110` declares its callback as:

```elixir
:addresses, related_view, ids when is_atom(related_view) and is_list(ids) ->
```

A binary is not a list, so no clause matches: `FunctionClauseError`, 500. This
affects `customers.addresses` and `customers.payment_demands` — the only
writable to-many relationships on the resources this client currently covers.
Controllers whose callback takes a binary id, such as
`merchant_tokens_controller.ex:120`, work correctly with the same dispatcher.

### What the client does

Refuses null linkage with an `ArgumentError` naming this entry, rather than
sending a request that becomes a 500. Builds to-many linkage as the array
JSON:API specifies and as `conn.ex:268` reads, because that is correct and
works wherever the controller callback matches — the mismatch is per-controller
and not something a client can detect.

### Asked of the API

Add the `nil` clause, and settle whether the related-data callback receives one
id or a list. Either convention is fine; having both is what produces the 500.

## FU-14 — Documented card expiry is never serialized

`CoreHTTP.Views.PaymentMethods.fields/0` declares `expiry_month` and
`expiry_year` (`views/payment_methods.ex:27-28`). The schema stores neither:
`Core.Consumer.PaymentMethod` has a single `field(:card_expiry, :date)`
(`consumer/payment_method.ex:53`). Neither view field carries a `from:`
mapping, so the serializer looks up struct keys that do not exist and drops
both without comment.

Confirmed against a running instance: no payment method carries either
attribute, and `card_expiry` is not exposed under any name.

`merchant_tokens` has the same defect. The view declares
`expiry` (`views/merchant_tokens.ex:20`); the schema field is
`expires_at` (`users/merchant_token.ex:22`), again with no `from:`.
`merchants.business_privacy_policy_url` is declared and never sent.

**There is currently no way to read a stored card's expiry date through the
v2 API**, which a merchant needs in order to prompt before a card lapses.

### What the client does

The manifest records these attributes because the view declares them, so the
generated readers exist and return nil. `Edge::PaymentMethod#expiry` is
documented as returning nil against today's API rather than removed, because
the fix upstream is a one-line `from:` and the reader will then work unchanged.

The exact set is pinned in `spec/contract/live_spec.rb`, so a field that starts
being sent shows up as a failing example rather than going unnoticed.

### Asked of the API

Add `from: :card_expiry` and derive the two integers, or expose `card_expiry`
directly and drop the pair from the view. Same for `merchant_tokens.expiry`
and `merchants.business_privacy_policy_url`.

## FU-15 — The OpenAPI document attributes six fields to the wrong resource

`beneficial_owners` is documented as carrying `icon_url`, `login_url`,
`logo_url`, `name`, `primary_colour` and `state`. Those six are exactly
`CoreHTTP.Views.FinancialInstitutions.fields/0`
(`views/financial_institutions.ex:16-24`). The beneficial owners view declares
only `ownership_percentage`, `created_at` and `updated_at`, and that is what a
running instance returns.

The manifest records them as `from: openapi-snapshot-only`, which is how they
are distinguishable from fields the view actually declares.

`payment_demands.amount_refunded_cents` is snapshot-only for a different
reason: it is in the OpenAPI document and in no view at all (see FU-16).

### What the client does

Nothing yet — `Edge::Resource` generates a reader for every attribute the
manifest records, whatever its provenance, so `BeneficialOwner#name` exists and
always returns nil. Honouring `from:` when generating readers is worth doing
before these resources ship.

### Asked of the API

Regenerate the OpenAPI document from the views. A published document that
attributes one resource's fields to another is worse than an incomplete one:
it is the artifact client generators are built against.

**Status:** acknowledged by the Edge team as an API-side issue. The client will
not work around it. See docs/api-todo.md.

## FU-16 — Partial refunds are accepted and then made impossible

`Core.Transactions.refund_payment_demand/*` (`transactions.ex:841-860`) inserts
the refund and then calls
`PaymentDemand.refunded_state_changeset/2` unconditionally, moving the demand
`succeeded -> refunded` with no regard to amount. `refunded_state_changeset`
validates the source state is `succeeded` (`payment_demand.ex:662`), so the
second partial refund against the same demand fails with *"must have been
successfully processed to be refunded"*.

Confirmed against a running instance: a **100-cent** refund against a
**10000-cent** demand moved the demand to `refunded`, and a further refund was
refused.

`amount_refunded_cents` appears nowhere in `lib/core`. Nothing accumulates a
refunded total, so there is no state from which partial refunds could be
supported even if the transition were conditional.

### What the client does

Nothing — refunds are commit 11. This is recorded so that commit is built
against what the API does rather than what a partial-refund API would do.
`Edge::RefundDemand` must not offer partial refunds as a supported workflow
while the first one closes the demand.

### Asked of the API

Only transition to `refunded` once the refunded total reaches the demand
amount, and serialize that total. Until then, document refunds as
all-or-nothing.

## FU-17 — `refund_demands.amount_currency` is a documented string that 500s

The view declares `amount_currency` as `{:string, ...}`
(`views/refund_demands.ex`). The schema is
`Ecto.Enum<values: [:USD]>`, and the changeset sets it with
`Ecto.Changeset.put_change/3` (`transactions.ex:85-87`), which does not cast.
A JSON string therefore reaches `Repo.insert` uncast:

```
** (Ecto.ChangeError) value "USD" for Core.Transactions.RefundDemand.amount_currency
   in `insert` does not match type #Ecto.Enum<values: [:USD]>
```

Sending the documented value for a documented field is a 500. **Omitting it
succeeds**, because the fallback is `payment_demand.amount_currency`, already
an atom loaded from the database.

### What the client does

Nothing yet. When refunds land in commit 11 the client must either omit
`amount_currency` or refuse it with an explanation, rather than passing a
caller's correct-looking `"USD"` through to a 500.

### Asked of the API

`cast` the attribute instead of `put_change`, so that a string is converted and
an unsupported currency is a 422 rather than a crash.

## FU-18 — There is no capture, void, cancel or authorize operation

Searched the whole router and every controller: the only lifecycle verbs are
`create` on `payment_demands`, `create` on `refund_demands`, and
`PATCH /v2/payment_demands/:id/confirm`. There is no `capture`, no `void`, no
`cancel` and no `authorize` action anywhere in `core_http/controllers`.

`capture_method` exists on the schema and reads `automatic` on every record
observed, including a live successful payment. Nothing sets it to anything else
through the API.

`confirm` is **not** a capture. It is two operations sharing a route
(`payment_demands_controller.ex:317-365`):

- for a payment demand, it is a **retry**, guarded by
  `is_confirmable_demand/1`, which requires `processor_state in [:failed]`
  (`transactions/payment.ex:26-28`);
- for a payment *intent*, it promotes the intent into a demand
  (`is_confirmable_intent/1`, states `[:incomplete, :ready]`).

Note that `payment_intents` has no route and no view of its own.
`find_payment_demand_by/4` falls back to `find_payment_intent_by/4`
(`payment_demands_controller.ex:379-390`) and the intent is rendered through
`Views.PaymentDemands`, so `GET /v2/payment_demands/:id` can return an intent
serialized as `type: "payment_demands"`.

This confirms RB-1 from the other direction: the authorize/capture/void split a
Solidus or Spree gateway is written against does not exist in this API, and no
amount of client work can supply it.

### What the client does

Commit 10 must ship `create` and `confirm` only, with `confirm` documented as a
retry of a failed demand rather than as a capture. `#capture` and `#void` must
not exist, for the same reason `PaymentMethod.create` does not: a method that
existed and 404ed would read as a server fault rather than as a capability the
API does not have.

Verified against a running instance rather than only read from the source:

```
PATCH /v2/payment_demands/:id/capture  -> 404 (no such route)
PATCH /v2/payment_demands/:id/confirm  -> 405 (route exists; demand was `processing`)
```

The 405 is the controller's `_data, _payload -> {:error, :method_not_allowed}`
clause, reached because the demand was not `failed`. Note that **405 is not in
the documented status list** for this API, and that it does not distinguish
"this route does not accept PATCH" from "this record is in the wrong state" —
which is the information a caller actually needs.

### Asked of the API

**Answered.** Deferred capture is not supported today for PCI compliance
reasons. It is planned, but the timeline depends on business growth and may be
more than a year out.

The client therefore ships `create` and `confirm` only, and will not offer
`#capture` or `#void` — for the same reason `PaymentMethod.create` does not
exist. `capture_method: "automatic"` should be documented as the only value the
API accepts, since it currently implies a manual counterpart that has no route.

## FU-19 — A create validation error names no field in its message

Creating a payment demand with only an amount answers with **ten** JSON:API
error objects whose `title` is the identical string `"can't be blank"`. Each
carries a distinct `source.pointer`; none carries a `detail`. A client that
renders titles alone shows the same sentence ten times.

The missing set is `amount_currency`, `purchase_reference`, `purchase_kind`,
`threeds_version`, `threeds_status`, `eci`, `directory_transaction_eid`,
`acs_transaction_eid`, `payer_timezone`, and the relationship
`billing_address` — which points at `/data/relationships/billing_address`
rather than an attribute, so a client that only understands attribute pointers
loses that one entirely.

Five of those are 3DS results. A live successful payment carries
`eci: "05"`, `threeds_status: "Y"`, `threeds_version: "2.2.0"` and a
`threeds_cryptogram` — values produced by a browser 3DS handshake. **A
server-side gateway cannot synthesize them**, which bounds what commit 10 can
honestly offer: creating a payment demand is not a purely server-side
operation.

### What the client does

`Edge::JSONAPI::ErrorObject#to_s` now prefixes the pointer's attribute name, so
the message reads `payer_timezone: can't be blank` and a batch of identical
titles becomes a list of field names. `APIError#errors_by_attribute` already
exposed the structured form.

### Asked of the API

Populate `detail` with something field-specific. `title` is defined as the
generic summary; ten identical ones are within spec but carry no information.
