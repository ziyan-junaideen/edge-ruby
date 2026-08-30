# frozen_string_literal: true

RSpec.describe Edge::Client do
  let(:secret_key) { "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB" }
  let(:client) { described_class.new(api_key: secret_key) }

  describe "credentials" do
    it "requires an api key" do
      expect { described_class.new }
        .to raise_error(Edge::ConfigurationError, /no api_key/)
    end

    it "refuses a publishable key with an actionable message" do
      # A publishable key would otherwise fail as an opaque 401 at the first
      # request, far from the configuration that caused it.
      expect { described_class.new(api_key: "ept_live_bQsnYGFoLvE2") }
        .to raise_error(Edge::ConfigurationError, /publishable \(browser\) key.*use the secret/m)
    end

    it "names the mode of the key it rejected, so the fix is unambiguous" do
      expect { described_class.new(api_key: "ept_sandbox_bQsnYGFoLvE2") }
        .to raise_error(Edge::ConfigurationError, /\(sandbox\)/)
    end

    it "accepts a credential it does not recognise" do
      expect { described_class.new(api_key: "some-oauth-bearer-token") }.not_to raise_error
    end

    it "reports no mode for an unrecognised credential rather than guessing" do
      expect(described_class.new(api_key: "some-oauth-bearer-token").mode).to be_nil
    end

    it "reports the mode of a recognised key" do
      expect(client.mode).to eq(:sandbox)
      expect(client).to be_sandbox
      expect(client).not_to be_live
    end
  end

  describe "the base URL" do
    it "defaults to the production API" do
      expect(client.config.base_url).to eq("https://api.tryedge.io/")
    end

    it "normalises a trailing slash so joining is predictable" do
      # Without this, URI.join against ".../v2" would discard "v2".
      overridden = described_class.new(api_key: secret_key, base_url: "https://example.test///")
      expect(overridden.config.base_url).to eq("https://example.test/")
    end

    it "rejects a value that is not an absolute http URL" do
      expect { described_class.new(api_key: secret_key, base_url: "not-a-url") }
        .to raise_error(Edge::ConfigurationError, /absolute http/)
    end

    it "raises an Edge error, not a URI error, on a malformed URL" do
      expect { described_class.new(api_key: secret_key, base_url: "http://[bad") }
        .to raise_error(Edge::ConfigurationError, /not a valid URL/)
    end

    it "rejects a base URL carrying a query or fragment" do
      # Appending the trailing slash after a query produces a base whose own
      # path silently evaporates on join, sending requests to the wrong place.
      ["https://api.tryedge.io/v2?x=1", "https://api.tryedge.io/v2#frag"].each do |value|
        expect { described_class.new(api_key: secret_key, base_url: value) }
          .to raise_error(Edge::ConfigurationError, /query or fragment/)
      end
    end

    it "rejects a base URL carrying userinfo" do
      expect { described_class.new(api_key: secret_key, base_url: "https://u:p@api.tryedge.io") }
        .to raise_error(Edge::ConfigurationError, /userinfo/)
    end

    it "refuses cleartext http for a remote host" do
      # The bearer token authorises money movement; it does not go out in the
      # clear because someone mistyped a scheme.
      expect { described_class.new(api_key: secret_key, base_url: "http://api.tryedge.io") }
        .to raise_error(Edge::ConfigurationError, /https/)
    end

    it "allows cleartext http for local development hosts" do
      %w[http://localhost:4001 http://127.0.0.1:4001 http://api.tryedge.test:4001].each do |value|
        expect { described_class.new(api_key: secret_key, base_url: value) }.not_to raise_error
      end
    end
  end

  describe "#url_for" do
    it "joins a relative path" do
      expect(client.url_for("v2/customers")).to eq("https://api.tryedge.io/v2/customers")
    end

    it "does not let a leading slash discard the base path" do
      base = described_class.new(api_key: secret_key, base_url: "https://example.test/api")
      expect(base.url_for("/v2/customers")).to eq("https://example.test/api/v2/customers")
    end

    it "allows an absolute URL on the configured origin" do
      expect(client.url_for("https://api.tryedge.io/v2/customers?page[limit]=5"))
        .to eq("https://api.tryedge.io/v2/customers?page[limit]=5")
    end

    it "refuses an absolute URL on another origin" do
      # This is the credential-exfiltration path: a pagination link or redirect
      # pointing elsewhere must never receive the bearer token.
      expect { client.url_for("https://evil.example/v2/customers") }
        .to raise_error(Edge::InsecureRedirectError, /evil\.example/)
    end

    it "refuses an absolute URL that differs only by scheme" do
      expect { client.url_for("http://api.tryedge.io/v2/customers") }
        .to raise_error(Edge::InsecureRedirectError)
    end

    it "refuses an absolute URL that differs only by port" do
      expect { client.url_for("https://api.tryedge.io:8443/v2/customers") }
        .to raise_error(Edge::InsecureRedirectError)
    end

    it "does not echo a credential carried in the refused URL" do
      # The URL itself carries the key here, so the assertion can actually
      # fail. A message built by interpolating the whole URL would leak it.
      hostile = "https://evil.example/x?token=#{secret_key}"

      expect { client.url_for(hostile) }
        .to raise_error(Edge::InsecureRedirectError) { |error|
          expect(error.message).not_to include(secret_key)
          expect(error.message).not_to include("QsnYGFo")
        }
    end

    it "refuses a scheme without an authority rather than passing it through" do
      # `https:evil.example/x` and `mailto:` carry a scheme but no `://`.
      # Matching only the hierarchical form would route these to the relative
      # branch, where URI.join returns them unchanged and unchecked.
      ["https:evil.example/x", "mailto:a@evil.example", "javascript:alert(1)",
       "data:text/html,x", "https:/api.tryedge.io/x"].each do |hostile|
        expect { client.url_for(hostile) }
          .to raise_error(Edge::InsecureRedirectError), "#{hostile} was not refused"
      end
    end

    it "accepts a host that differs only in case" do
      # Hostnames are case-insensitive. URI.parse normalises the scheme but not
      # the host, so without explicit downcasing a legitimate link is refused.
      expect(client.url_for("https://API.TRYEDGE.IO/v2/customers"))
        .to eq("https://api.tryedge.io/v2/customers")
    end

    it "strips userinfo from an otherwise acceptable URL" do
      # The host is correct so no token escapes, but userinfo on a
      # server-supplied link would become a Basic auth header on our request.
      expect(client.url_for("https://someone:secret@api.tryedge.io/v2/customers"))
        .to eq("https://api.tryedge.io/v2/customers")
    end

    it "raises an Edge error, not a URI error, on an unusable path" do
      # Callers are told they can rescue Edge::Error for everything.
      expect { client.url_for("v2/cust omers") }
        .to raise_error(Edge::Error, /could not build a URL/)
    end
  end

  describe "#same_origin?" do
    it "accepts an equivalent explicit default port" do
      expect(client.same_origin?("https://api.tryedge.io:443/v2/customers")).to be(true)
    end

    it "rejects a host that merely shares a suffix" do
      expect(client.same_origin?("https://api.tryedge.io.evil.example/v2")).to be(false)
    end

    it "rejects an unparseable URL rather than raising" do
      expect(client.same_origin?("http://[bad")).to be(false)
    end
  end

  describe "requests" do
    it "sends the JSON:API media type, bearer auth and a user agent" do
      stub = stub_request(:get, "https://api.tryedge.io/v2/customers")
             .with(headers: {
                     "Authorization" => "Bearer #{secret_key}",
                     "Accept" => "application/vnd.api+json",
                     "Content-Type" => "application/vnd.api+json",
                     "User-Agent" => %r{edge-ruby/}
                   })
             .to_return(status: 200, body: "{}")

      client.get("v2/customers")

      expect(stub).to have_been_requested
    end

    it "always sends a usable user agent without application metadata" do
      # The API marks User-Agent required but does not require the caller to
      # identify their application, so zero configuration must still work.
      stub = stub_request(:get, "https://api.tryedge.io/v2/customers")
             .with(headers: { "User-Agent" => %r{\Aedge-ruby/#{Edge::VERSION} ruby/} })
             .to_return(status: 200, body: "{}")

      client.get("v2/customers")

      expect(stub).to have_been_requested
    end

    it "prepends application metadata when it is given" do
      configured = described_class.new(api_key: secret_key, app_info: "Acme/1.2")
      stub = stub_request(:get, "https://api.tryedge.io/v2/customers")
             .with(headers: { "User-Agent" => %r{\AAcme/1\.2 edge-ruby/} })
             .to_return(status: 200, body: "{}")

      configured.get("v2/customers")

      expect(stub).to have_been_requested
    end

    it "passes query parameters through" do
      stub = stub_request(:get, "https://api.tryedge.io/v2/customers")
             .with(query: { "sort" => "-created_at" })
             .to_return(status: 200, body: "{}")

      client.get("v2/customers", params: { "sort" => "-created_at" })

      expect(stub).to have_been_requested
    end

    it "sends a body on write requests" do
      stub = stub_request(:post, "https://api.tryedge.io/v2/customers")
             .with(body: '{"data":{}}')
             .to_return(status: 201, body: "{}")

      client.post("v2/customers", body: '{"data":{}}')

      expect(stub).to have_been_requested
    end

    it "accepts an injected connection so a suite can drive it without a network" do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("https://api.tryedge.io/v2/customers") { [200, {}, "{}"] }
      injected = described_class.new(
        api_key: secret_key,
        connection: Faraday.new { |f| f.adapter(:test, stubs) }
      )

      expect(injected.get("v2/customers").status).to eq(200)
      stubs.verify_stubbed_calls
    end

    it "still authenticates through an injected connection" do
      # Injecting a connection is the documented way to add middleware. If
      # credentials only came from the connection this built, every request
      # through an injected one would go out anonymous and 401 with no clue
      # as to why.
      seen = nil
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("https://api.tryedge.io/v2/customers") do |env|
        seen = env.request_headers
        [200, {}, "{}"]
      end
      injected = described_class.new(
        api_key: secret_key,
        connection: Faraday.new { |f| f.adapter(:test, stubs) }
      )

      injected.get("v2/customers")

      expect(seen["Authorization"]).to eq("Bearer #{secret_key}")
      expect(seen["Accept"]).to eq(described_class::MEDIA_TYPE)
      expect(seen["User-Agent"]).to include("edge-ruby/")
    end

    it "applies timeouts through an injected connection" do
      seen = nil
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("https://api.tryedge.io/v2/customers") do |env|
        seen = env.request
        [200, {}, "{}"]
      end
      injected = described_class.new(
        api_key: secret_key, timeout: 7, open_timeout: 3,
        connection: Faraday.new { |f| f.adapter(:test, stubs) }
      )

      injected.get("v2/customers")

      expect(seen.timeout).to eq(7)
      expect(seen.open_timeout).to eq(3)
    end
  end

  describe "credential containment" do
    it "does not keep the key on the connection object" do
      # Faraday::Connection has no redacting inspect, so anything stored in its
      # headers reaches Sentry, better_errors, pp and binding.irb. Credentials
      # are attached per request instead.
      connection = client.send(:connection)

      expect(connection.inspect).not_to include(secret_key)
      expect(connection.headers["Authorization"]).to be_nil
    end

    it "keeps the connection reader private" do
      expect { client.connection }.to raise_error(NoMethodError, /private method/)
    end

    it "freezes its configuration so the validated key cannot be swapped" do
      # Otherwise a publishable key could be assigned after validate! passed,
      # and `mode` would keep reporting the key it no longer sends.
      expect { client.config.api_key = "ept_live_bQsnYGFoLvE2" }
        .to raise_error(FrozenError)
    end
  end

  describe "#inspect" do
    it "does not include the api key" do
      expect(client.inspect).not_to include("QsnYGFo")
      expect(client.inspect).to include("mode=:sandbox")
    end

    it "does not leak the key through the configuration either" do
      expect(client.config.inspect).not_to include("QsnYGFo")
      expect(client.config.inspect).to include("[FILTERED]")
    end
  end
end
