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

### Changed

- A validation error now names the field it is about. The API answers a
  malformed create with a batch of error objects whose titles are identical and
  whose pointers are not — ten of them, every one reading `can't be blank` —
  so a repeated `HTTP 422 can't be blank` became
  `purchase_reference: can't be blank; payer_timezone: can't be blank; …`.
- Base URL validation moved to `Edge::BaseUrl`. No behaviour change, and the
  four helpers that were private on `Configuration` stay private.

### Fixed

- `URI::DEFAULT_PARSER.escape` warned on Ruby 3.4; the parser is now chosen at
  load time, since 3.2 and 3.3 have no `RFC2396_PARSER` to name.
