# Pointing the client at another host

The client talks to `https://api.tryedge.io` by default. `base_url:` points it
elsewhere: a staging host, a proxy, or a local stand-in whose certificate is
issued by a private CA such as [mkcert](https://github.com/FiloSottile/mkcert).

```ruby
client = Edge::Client.new(
  api_key: ENV.fetch("EDGE_SANDBOX_SECRET"),
  base_url: "https://api.example.test:4001",
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

A certificate generated on someone else's machine was signed by their mkcert
root, which will not be in your `mkcert -CAROOT`. Compare the issuer against
your root before assuming the CA file is the problem:

```sh
echo | openssl s_client -connect api.example.test:4001 2>/dev/null \
  | openssl x509 -noout -issuer
openssl x509 -in "$(mkcert -CAROOT)/rootCA.pem" -noout -subject
```

If they name different people, regenerate the certificate with your own mkcert
rather than hunting for theirs.

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

## Credentials

Use a **secret** key (`ept_sandbox_s…` / `ept_live_s…`) from the Edge
dashboard. This gem refuses a publishable key (`ept_…_b…`) with an
explanation, because those are for the browser SDK and cannot authenticate
server-side requests.

The key selects live or sandbox; the host is the same for both.

## Running the contract checks

`spec/contract/live_spec.rb` compares `contract/manifest.yml` against a running
API. It is excluded from the default suite — which is forbidden from touching
the network at all — and runs only when asked:

```sh
EDGE_LIVE_URL=https://api.example.test:4001 \
EDGE_LIVE_KEY="$EDGE_SANDBOX_SECRET" \
EDGE_LIVE_CA="$(mkcert -CAROOT)/rootCA.pem" \
  bundle exec rspec spec/contract/live_spec.rb --tag live
```

Set `EDGE_LIVE_INSECURE=1` instead of `EDGE_LIVE_CA` to skip verification.

The checks are read-only. The write half of the lifecycle is not repeatable —
every refund permanently spends part of a succeeded payment demand's balance,
and a demand that succeeds usually needs a 3DS handshake to create — so it is
exercised by hand against sandbox rather than asserted here.
