# frozen_string_literal: true

RSpec.describe Edge do
  let(:secret_key) { "ept_sandbox_sQsnYGFoLvE2Qt7tmsvuDESB" }

  after { described_class.reset! }

  describe ".configure" do
    it "builds a default client" do
      described_class.configure { |config| config.api_key = secret_key }

      expect(described_class.default_client).to be_a(Edge::Client)
      expect(described_class.default_client.mode).to eq(:sandbox)
    end

    it "carries settings through to the client" do
      described_class.configure do |config|
        config.api_key = secret_key
        config.base_url = "https://api.tryedge.test:4001"
        config.app_info = "Acme/1.2"
      end

      expect(described_class.default_client.config.base_url).to eq("https://api.tryedge.test:4001/")
      expect(described_class.default_client.config.app_info).to eq("Acme/1.2")
    end

    it "refuses a publishable key at configuration time" do
      expect { described_class.configure { |config| config.api_key = "ept_live_bQsnYGFo" } }
        .to raise_error(Edge::ConfigurationError, /publishable/)
    end

    it "leaves the previous client installed when the new one is rejected" do
      # A half-applied configuration is worse than a rejected one: the caller
      # sees an exception and assumes nothing changed.
      described_class.configure { |config| config.api_key = secret_key }
      original = described_class.default_client

      expect { described_class.configure { |c| c.api_key = "ept_live_bQsnYGFo" } }
        .to raise_error(Edge::ConfigurationError)

      expect(described_class.default_client).to equal(original)
    end

    it "does not retain the credential on the module after it returns" do
      described_class.configure { |config| config.api_key = secret_key }

      leaked = described_class.instance_variables.select do |name|
        described_class.instance_variable_get(name).inspect.include?("QsnYGFo")
      end
      expect(leaked).to be_empty
    end

    it "honours an explicit nil timeout rather than substituting the default" do
      # nil is Faraday'''s way of saying "no timeout"; dropping it would
      # silently impose 30s on someone who asked for none.
      described_class.configure do |config|
        config.api_key = secret_key
        config.timeout = nil
      end

      expect(described_class.default_client.config.timeout).to be_nil
    end
  end

  describe ".default_client" do
    it "raises rather than silently building an unauthenticated client" do
      expect { described_class.default_client }
        .to raise_error(Edge::ConfigurationError, /not configured/)
    end
  end

  describe ".reset!" do
    it "drops configuration so it cannot leak between examples" do
      described_class.configure { |config| config.api_key = secret_key }
      expect(described_class).to be_configured

      described_class.reset!

      expect(described_class).not_to be_configured
    end
  end
end
