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
