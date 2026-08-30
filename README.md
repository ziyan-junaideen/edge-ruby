# edge-ruby

A Ruby client for the [Edge Payment Technologies](https://tryedge.io) HTTP API,
for Rails, Sinatra and plain Rack applications.

> **Unofficial.** This is an independent client, not published, supported or
> certified by Edge Payment Technologies. It is not the official SDK. Bugs here
> are bugs here — report them on this repository, not to Edge support.

> **Pre-release.** No published gem yet, and no usable release — this repository
> currently contains the API contract and its provenance, and no library code.
> The public API is still being settled and will change without notice until
> 0.1.0. See [`docs/release-blockers.md`](docs/release-blockers.md) for what is
> gating the first release.

## Naming

The gem is `edge-ruby`; the namespace is `Edge`.

`edge` is taken on RubyGems by an unrelated ActiveRecord graph library, so the
repository name doubles as the package name — the same shape as `stripe-ruby`.

`Edge` is a broad top-level constant and can collide with an application's own
`Edge` model. That is an accepted tradeoff, recorded here so it is a choice
rather than a surprise. The gem will ship both `lib/edge.rb` and a
`lib/edge-ruby.rb` shim, so `gem "edge-ruby"` works without a `require:` option.

## Design commitments

These are settled decisions that constrain the implementation. **None of them is
built yet** — they describe what the client will do, not what it does.

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
  snapshot does not know about; parsing must not break when that happens again.
- **Writes are explicit.** No generic dirty tracking, no `#save`. The server
  source does not express which attributes are writable per operation, so the
  client states it per operation rather than inferring it.
- **Reads retry; writes do not.** A write opts into retries only after its
  server-side replay contract has been exercised against sandbox.
- **Idempotency keys are yours.** The client will not mint ephemeral ones: a key
  generated inside a call cannot protect a job retried in another process.
- **Secrets are redacted by default.** The API returns webhook signing keys,
  merchant tokens and KYC identifiers. None of them appear in `inspect`,
  exception messages, logs or instrumentation. Request and response bodies are
  not logged.

## What the API cannot do

Worth knowing before designing against it. Full detail and evidence in
[`docs/release-blockers.md`](docs/release-blockers.md).

- **No capture and no void.** `PATCH .../confirm` means "ready for processing",
  not capture — its guard only matches a *failed* demand. The processor layer
  implements capture and void, but nothing calls either function and no route
  exposes them. This client will not fake them.
- **A partial refund closes the payment demand.** Any refund moves the demand
  to `refunded` regardless of amount, and no second refund is possible against
  it. Nothing tracks a refunded total. Verified against a running instance; see
  [`docs/release-blockers.md`](docs/release-blockers.md), FU-16.
- **`GET /v2/financial_institutions` returns the wrong `data.type`.**
- **Collections are not paginated.** Every record comes back in one response.
  See [`docs/pagination.md`](docs/pagination.md).
- **Running against a local instance.** The dev API uses an mkcert
  certificate that Ruby does not trust by default. See
  [`docs/local-development.md`](docs/local-development.md).

## The contract directory

`contract/` is what this client is built against, and it comes first because
everything else depends on it.

| File | |
| --- | --- |
| `contract/manifest.yml` | Source of truth: operations, relationships, writeability, enums, sensitive fields. Attributes and relationships come from the Phoenix source; routes, operations and a few unresolvable enum value sets come from the snapshot, each marked with its origin |
| `contract/openapi.json` | A vendored snapshot. Cross-checks the source, and supplies the route list |
| `contract/PROVENANCE.md` | Where each came from and how far it can be trusted |
| `contract/bin/extract_manifest.rb` | Regenerates the manifest |

```sh
contract/bin/extract_manifest.rb /path/to/edge/ept > contract/manifest.yml
```

The generator reports what it cannot resolve rather than guessing, and its
warnings are reviewed on every regeneration. Read `contract/PROVENANCE.md`
before trusting `openapi.json` for anything — it was generated from an
abandoned branch and documents at least one field no server has.

## License

MIT. See [`LICENSE`](LICENSE).
