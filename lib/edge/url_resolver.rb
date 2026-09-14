# frozen_string_literal: true

require "uri"

module Edge
  # Turns a path or a server-supplied link into a URL that is safe to send a
  # bearer token to.
  #
  # Separate from Client because it is the security boundary: every URL the
  # client authenticates against passes through here, including pagination
  # links, which are attacker-influenced input in the sense that matters — the
  # client did not construct them.
  class UrlResolver
    # Anything with a scheme is treated as absolute and must pass the origin
    # check. Deliberately not `://`: `https:evil.example/x` and
    # `mailto:a@evil.example` carry a scheme without an authority, and matching
    # only the hierarchical form would route them to the relative branch where
    # `URI.join` returns them unchanged and unchecked.
    ABSOLUTE = /\A[a-z][a-z0-9+.-]*:/i

    attr_reader :base_url

    def initialize(base_url)
      @base_url = base_url
      @base = URI.parse(base_url)
    end

    # Joins a relative API path onto the base URL, or verifies an absolute one
    # against it.
    #
    # `URI.join` is not usable directly: a path with a leading slash would
    # discard the base's own path, and an absolute URL would replace the origin
    # outright. Both are how a caller-supplied or server-supplied string ends
    # up pointing somewhere the credential should never go.
    def resolve(path)
      candidate = path.to_s
      return verify(candidate) if candidate.match?(ABSOLUTE)

      URI.join(base_url, candidate.sub(%r{\A/+}, "")).to_s
    rescue URI::Error => e
      raise Error, "could not build a URL from #{candidate.inspect}: #{e.message}"
    end

    # True when `url` addresses the same scheme, host and effective port as the
    # base URL.
    def same_origin?(url)
      origin(URI.parse(url.to_s)) == origin(@base)
    rescue URI::Error
      false
    end

    private

    def verify(url)
      raise InsecureRedirectError.new(url, base_url) unless same_origin?(url)

      normalize(url)
    end

    # Echoing the caller's string back would carry two things forward that
    # should not survive: host casing, which makes otherwise identical URLs
    # look different in logs and cache keys, and userinfo, which Faraday turns
    # into a Basic auth header. The host has already been checked, so nothing
    # here changes where the request goes.
    def normalize(url)
      uri = URI.parse(url)
      uri.password = nil
      uri.user = nil
      uri.host = uri.host.downcase if uri.host
      uri.to_s
    end

    # Scheme and host are case-insensitive (RFC 3986 3.2.2). URI.parse
    # normalises the scheme but not the host, so the host is downcased here;
    # without this a legitimately differently-cased link is refused.
    def origin(uri)
      [uri.scheme&.downcase, uri.host&.downcase, uri.port]
    end
  end
end
