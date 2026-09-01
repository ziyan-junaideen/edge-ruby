# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from 1.0.0; until then the public API may change in any release.

## [Unreleased]

### Added

- Vendored API contract: `contract/manifest.yml` derived from the Edge Phoenix
  source, a cross-check snapshot of `openapi.json`, and provenance for both.
- `contract/bin/extract_manifest.rb`, which regenerates the manifest and
  reports what it cannot resolve rather than guessing.
- `docs/pagination.md`, recording production's unpaginated behaviour separately
  from the unmerged cursor proposal.
- `docs/release-blockers.md`, recording the API-side gaps that constrain what
  this client may expose.
- Package identity: name, namespace, MIT license and unofficial positioning.
- `Configuration#ssl`, passed through to Faraday, so a development instance
  behind a private CA can be reached: Ruby's OpenSSL never consults the macOS
  keychain, so a `mkcert -install`ed root is invisible to it. Options that
  switch verification off are refused for any host but loopback and
  `.test`/`.local`, checked when the client is built so that the finished pair
  is judged once whichever order the two were assigned in.
- `retriable:` on `create`, which opts a write into being repeated after a
  transient failure. Both halves are required: the contract must record a
  replay contract, and the request must carry the `idempotency_key` the server
  replays it by, since without one a repeat inserts a second record. `update`
  takes no such option and refuses the keyword — nothing in the API replays a
  PATCH. The low-level `Client#post` is unchanged and still checks only the
  contract; it is the documented escape hatch.
- `Edge::PaymentMethod#expiry_known?`, because the API omits card expiry
  entirely today (docs/release-blockers.md, FU-14) and a caller needs to tell
  "not sent" from a value.
- `docs/local-development.md`, on pointing the client at a local instance.
- `docs/api-todo.md`, the API-side findings this client is waiting on.
- `spec/contract/live_spec.rb`, which checks the manifest against a running
  instance. Excluded from the default suite, which may not touch the network.
- `Edge::PaymentDemand`, with only the operations the API has: `create`,
  `retrieve`, `list`, `update` and `confirm`. **No `#capture` and no `#void`** —
  there is no route for either, `confirm` is not capture, and deferred capture
  is unsupported today for PCI compliance reasons.
- `Edge::PaymentDemand#intent?` and `#demand?`. `POST /v2/payment_demands`
  creates a payment *intent* unless the request says `confirmed: true`, and
  renders it through the payment demand view — same type, same route. Nothing
  distinguishes the two but `processor_state`, whose intent values are disjoint
  from the demand's. Only a demand has been charged.
- State predicates that tolerate a state this client has not heard of: every
  one answers false rather than raising, `#state_known?` tells that apart from
  a state that is genuinely none of them, and `#demand?` answering false for an
  unknown state is the safe direction — a new state must never read as "this
  was charged".
- `Edge::Resource::CustomActions`, which declares a manifest `custom_action` as
  a class method taking an id and an instance method taking none. Opt-in rather
  than generated, because a route existing is not the same as this client
  knowing what it means. `#confirm` returns a new record and leaves its
  receiver alone; it will not fall back to `Edge.default_client`, for the same
  reason `Relationship#fetch` will not.
- `Edge::PaymentDemand#verification_passed?`, false whenever an AVS or CVC
  check is missing rather than treating "not checked" as "checked and fine".
- `docs/payment-demands.md`, on the two kinds of record this endpoint returns,
  the two ways to charge, and the five operations the API does not have.
- `Edge::Webhook`, verifying a v3 delivery: HMAC-SHA256 over
  `"<timestamp>.<raw body>"`, compared with `OpenSSL.secure_compare`, with a
  freshness window checked in both directions so a fast clock cannot accept a
  delivery dated far ahead. Cross-checked byte for byte against the server's
  own `:crypto.mac/4`, including multi-byte UTF-8 in the secret and the body.
- `Edge::Webhook.test_signature`, so a consumer's suite does not have to
  reimplement the signing scheme and then drift from it.
- `Edge::RefundDemand`, `Edge::Event`, `Edge::WebhookSubscription` and
  `Edge::WebhookDelivery`.
- `Edge::Event#code`, joining the event code the server stores in two columns.
  What documentation and dashboards call the event —
  `transaction.payment_demands.succeeded` — is not in `slug`, which carries
  only `"succeeded"`; `resource_type` carries the rest. The joined form exists
  server-side as a local variable used to match subscriptions and is never
  stored or delivered, so `subscription.subscribed_to?(event.slug)` is false
  every time.
- `Edge::WebhookSubscription.archive`, the only status change the API honours.
- `Edge::RefundDemand#errored?`, distinct from `#failed?`. `errored` is its own
  terminal state, and a handler that waits for `failed` waits forever.
- `Edge::SignatureVerificationError`, which never carries the secret or the
  body.
- `docs/webhooks.md`, on why a valid signature does not mean a new delivery.

### Changed

- `Edge::WebhookSubscription.update` refuses `status`, `secret_key`,
  `archived_at` and the merchant. The controller drops all of them before the
  changeset runs, so a merchant pausing deliveries got a `200`, a subscription
  still reporting `active?`, and deliveries still flowing.
- `Edge::RefundDemand.create` requires the payment demand it refunds and a
  reason, and refuses attributes the changeset does not cast — `state` above
  all, which is forced to `pending` before any cast runs. The controller reads
  the payment demand linkage before validating anything, so omitting it was a
  500 rather than a validation error.
- `refund_demands.amount_currency` is refused. It is inherited from the payment
  demand and set with `put_change`, which does not cast, so the documented
  `"USD"` is answered with a 500 rather than a validation error (FU-17).
- A `custom` refund reason without a `reason_note`, and a note over 500
  characters, are both refused before the request is sent — the server rejects
  them with an error naming no field.
- Only v3 webhook signatures are verified. v1 and v2 send a constant
  `Base64(SHA1(secret_key))` that does not take the body as an input; a
  `verify_v1` would be a method whose name promises what it cannot do. Passing
  a legacy header raises an error naming the delivery version rather than
  reporting a mismatch.
- `capture_method: "manual"` is refused on payment demands. The API accepts it
  and it reaches the processor as an authorization that **nothing can capture
  or void** — it sits against the cardholder's account until the processor
  expires it. The one place this client declines something the server allows;
  `client.post` remains the escape hatch.
- Attributes marked `readonly: true` are no longer recorded as unwritable
  wholesale. For attributes the flag only annotates the generated OpenAPI
  document; nothing on the write path reads it, and all seven 3DS fields on
  `payment_demands` are cast on create while `payer_timezone` is *required*.
  Recording them as unwritable made `PaymentDemand.create` impossible to call.
  `contract/bin/extract_manifest.rb` carries the exceptions with their
  evidence. See docs/release-blockers.md, FU-21.
- `PaymentDemand.update` refuses the attributes `PATCH` accepts and then
  discards. The manifest's `writable` flag has no per-operation dimension, and
  the update changeset casts a much smaller set than create does — the 3DS
  results, `capture_method` and `idempotency_key` are answered `200` and
  dropped. A demand can only be updated while it is `failed`.
- An attribute the manifest carries from the OpenAPI snapshot alone gets no
  reader. A reader is a promise the value is there, and
  `amount_refunded_cents` returning nil forever reads as "nothing refunded
  yet". Still reachable through `#[]`, and reported by `#unknown_attributes`
  if a server ever starts sending one.
- `spec/contract/live_spec.rb` treats a 5xx as "not readable" and asserts the
  set of such resources is empty in an example of its own, so one broken
  endpoint costs one failure with a list attached rather than blinding the five
  drift checks after it. Eight resources currently fail it (FU-22).

- `payment_demands` is no longer marked `idempotent_writes`, so `retriable:`
  refuses it. Its view documents `idempotency_key` as "a unique value that
  prevents double charging"; exercised against a running instance, the key is
  dropped on create and two identical requests produced two payment demands.
  See docs/release-blockers.md, FU-20. Refunds are unaffected and proven.
- A validation error now names the field it is about. The API answers a
  malformed create with a batch of error objects whose titles are identical and
  whose pointers are not — ten of them, every one reading `can't be blank` —
  so a repeated `HTTP 422 can't be blank` became
  `purchase_reference: can't be blank; payer_timezone: can't be blank; …`.
- Base URL validation moved to `Edge::BaseUrl`. No behaviour change, and the
  four helpers that were private on `Configuration` stay private.

### Fixed

- `Request#resource_name` matched only the first path segment, so
  `PATCH /v2/payment_demands/:id/confirm` resolved to `payment_demands` and
  could inherit its replay contract. It now stops at a member and answers nil
  for anything deeper, which is the right answer for every sub-resource the API
  has: `confirm` on a failed demand is a *retry of the charge*, so replaying it
  charges again.
- `URI::DEFAULT_PARSER.escape` warned on Ruby 3.4; the parser is now chosen at
  load time, since 3.2 and 3.3 have no `RFC2396_PARSER` to name.
