# Security policy

## This is an unofficial client

`edge-ruby` is not published, supported or certified by Edge Payment
Technologies. Do not report vulnerabilities in this client to Edge support, and
do not treat this document as describing Edge's own policy.

## Reporting a vulnerability in this client

Open a private security advisory on this repository, or email the maintainer.
Please do not open a public issue for anything exploitable.

Include the affected version, what an attacker can achieve, and a minimal
reproduction. Describe the class of problem rather than attaching a working
exploit.

## Reporting a vulnerability in the Edge API

Report it to Edge directly at <support@tryedge.io>. If you found it through this
client, saying so helps, but the fix is theirs.

## Status: pre-release, no code yet

This repository currently contains the API contract and its provenance. There is
no `lib/`, no test suite and no published gem. Everything in the next section is
a **design commitment that will be enforced by tests**, not behaviour you can
rely on today. This notice comes out when the code and its security tests land.

## What this client will protect

- **Credentials stay on their origin.** Pagination links and redirects are
  followed only when scheme, host and port match the configured base URL. A
  cross-origin link is refused rather than handed the bearer token.
- **Secrets are not printed.** The API returns webhook signing keys, merchant
  tokens and KYC identifiers such as national ID numbers and dates of birth.
  None appear in `inspect`, exception messages, logs or instrumentation
  payloads. Request and response bodies are not logged by default.
  `#raw` is deliberately unredacted; that is documented where it is defined.
- **Writes are not replayed.** A write is retried only when its resource
  operation has a verified server-side replay contract and the caller supplied
  an idempotency key. The client does not mint ephemeral keys, which would
  imply a safety it cannot provide across processes.
- **Webhook signatures are verified properly.** The v3 scheme sends
  `edge-signature: t=<unix seconds>,v3=<lowercase hex>`, where the MAC is
  HMAC-SHA256 over the literal string `"<timestamp>.<raw body>"` keyed by the
  subscription's secret — not over the body alone. Verification uses the exact
  received bytes, a constant-time comparison, and a freshness window on `t`.

## What it will not protect

- **Webhook verification is not replay prevention.** A valid delivery can be
  retried or redelivered inside the tolerance window. Deduplicate on event ID.
- **Legacy v1/v2 webhook signing offers no integrity.** That header is a
  constant derived from the subscription secret and is not a function of the
  body. This client verifies v3 only and will not present the legacy header as
  verification.
- **Over-refunding is not prevented.** The Edge API does not check refunds
  against a remaining balance. Callers must track refunded totals themselves.
