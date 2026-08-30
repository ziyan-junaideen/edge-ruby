# Pointing the client at a local Edge instance

The Edge API runs locally over HTTPS on a certificate issued by
[mkcert](https://github.com/FiloSottile/mkcert), typically at
`https://api.tryedge.test:4001`.

```ruby
client = Edge::Client.new(
  api_key: ENV.fetch("EDGE_SANDBOX_SECRET"),
  base_url: "https://api.tryedge.test:4001",
  ssl: { ca_file: "#{`mkcert -CAROOT`.strip}/rootCA.pem" }
)
```

## Why `ssl:` is needed at all

Ruby does not use the operating system's trust store. `mkcert -install` adds
its root to the macOS keychain, which is why the browser and `curl` accept the
certificate; Ruby's OpenSSL reads its own file, named by
`OpenSSL::X509::DEFAULT_CERT_FILE` — usually something under
`/usr/local/etc/openssl@3` — and never consults the keychain. So a certificate
every other tool on the machine trusts is rejected here, with

```
SSL_connect returned=1 errno=0 state=error: certificate verify failed
(unable to get local issuer certificate)
```

`ssl:` is passed through to Faraday, so any option the adapter understands
works. It is ignored when a connection is injected, since that carries its own.

### Check which CA actually signed the certificate

A certificate checked into the API repository was signed by whichever
developer generated it, and their root will not be in your `mkcert -CAROOT`.
Compare the issuer against your root before assuming the CA file is the problem:

```sh
echo | openssl s_client -connect api.tryedge.test:4001 2>/dev/null \
  | openssl x509 -noout -issuer
openssl x509 -in "$(mkcert -CAROOT)/rootCA.pem" -noout -subject
```

If they name different people, regenerate the certificate with your own mkcert
rather than hunting for theirs. From the API repository:

```sh
mkcert -cert-file priv/cert/_wildcard.tryedge.test+3.pem \
       -key-file  priv/cert/_wildcard.tryedge.test+3-key.pem \
       "*.tryedge.test" tryedge.test localhost bore.tryedge.io
```

Note that `curl` on macOS is built against SecureTransport and **ignores
`--cacert` entirely**, verifying against the keychain instead. A successful
`curl --cacert ...` therefore says nothing about whether that CA file is the
right one. Ruby is the honest check.

### Turning verification off

```ruby
ssl: { verify: false }
```

Allowed only for loopback and `.test`/`.local` hosts — the same hosts for which
`base_url` may use plain `http`. Against any other host this raises
`Edge::ConfigurationError`, in either assignment order, because this client
sends a bearer token that authorises money movement and unverified TLS hands it
to whoever answers the connection.

Prefer `ca_file`. `verify: false` also disables hostname checking, so it hides
the misconfiguration rather than fixing it.

## Getting credentials

The API repository has a mix task that prints tokens for a merchant:

```sh
mix core.merchant_tokens_for "Edge"
```

Use the **secret** key (`ept_sandbox_s…` / `ept_live_s…`). This gem refuses a
publishable key (`ept_…_b…`) with an explanation, because those are for the
browser SDK and cannot authenticate server-side requests.

`live` and `sandbox` are separate schemas in one database selected by the
token, not separate hosts, so the same `base_url` serves both.

## Running the contract checks against it

`spec/contract/live_spec.rb` compares `contract/manifest.yml` against a running
instance. It is excluded from the default suite — which is forbidden from
touching the network at all — and runs only when asked:

```sh
EDGE_LIVE_URL=https://api.tryedge.test:4001 \
EDGE_LIVE_KEY="$(mix core.merchant_tokens_for Edge | grep sandbox_s)" \
EDGE_LIVE_CA="$(mkcert -CAROOT)/rootCA.pem" \
  bundle exec rspec spec/contract/live_spec.rb --tag live
```

Set `EDGE_LIVE_INSECURE=1` instead of `EDGE_LIVE_CA` to skip verification.

The checks are read-only. The write half of the lifecycle is not repeatable —
a refund moves its payment demand to `refunded`, after which no further refund
is possible against it (docs/release-blockers.md, FU-16) — so those findings
are recorded there rather than asserted here.
