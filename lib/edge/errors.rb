# frozen_string_literal: true

module Edge
  # Raised when the client is asked to do something it cannot be configured to
  # do: a missing key, a publishable key on the server, an unusable base URL.
  class ConfigurationError < Error; end

  # Raised when a URL would take an authenticated request off the configured
  # origin. Following such a URL with the bearer token attached would hand the
  # credential to whoever supplied it.
  class InsecureRedirectError < Error
    attr_reader :url, :base_url

    def initialize(url, base_url)
      @url = url
      @base_url = base_url
      super("refusing to send credentials to #{origin_of(url)}; " \
            "the configured origin is #{origin_of(base_url)}")
    end

    private

    def origin_of(url)
      uri = URI.parse(url.to_s)
      port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
      "#{uri.scheme}://#{uri.host}#{port}"
    rescue URI::InvalidURIError
      "an unparseable URL"
    end
  end
end
