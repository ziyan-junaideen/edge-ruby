# frozen_string_literal: true

require "uri"

module Edge
  # One HTTP request, held as a value so that a retry sends byte-for-byte what
  # the first attempt sent.
  #
  # That matters more than it looks: a replayed write must carry the identical
  # idempotency key it started with, and rebuilding the body between attempts
  # is how a client accidentally sends a fresh key and charges someone twice.
  # Frozen at construction so that guarantee is structural rather than a
  # convention the next edit can quietly break.
  #
  # `verb` rather than `method`: a Struct member named `method` overrides
  # Object#method, which breaks `respond_to?`-style introspection and anything
  # that reaches for `request.method(:foo)`.
  Request = Struct.new(:verb, :url, :body, :params, :headers, :retriable, keyword_init: true) do
    # The route segment this request addresses: `/v2/payment_demands/<id>` is
    # `payment_demands`. Used to look the operation up in the contract, which
    # is keyed by route name rather than by JSON:API type — the two diverge for
    # financial_institutions (see docs/release-blockers.md, RB-3).
    def resource_name
      URI.parse(url.to_s).path.to_s[%r{\A/v\d+/([a-z_]+)}, 1]
    rescue URI::Error
      nil
    end

    def safe? = RetryPolicy.safe_method?(verb)

    # Whether this operation may be sent again. Reads are safe by definition;
    # a write is only retriable when the caller has said so explicitly, and
    # `nil` means "decide from the method" rather than "yes".
    def retriable?
      retriable.nil? ? safe? : retriable
    end

    # A Struct prints every member, and `body` carries whatever the caller is
    # writing — a customer's email, name, phone and address on a create. This
    # object is live in Transport's stack frames, so any exception reporter
    # that renders local variables would ship the lot. Headers carry the bearer
    # token, and the query string carries filter values. None of it is printed.
    def inspect
      "#<#{self.class.name} #{verb.to_s.upcase} #{Redaction.scrub_query(url.to_s)} " \
        "bytes=#{body.to_s.bytesize} retriable=#{retriable?}>"
    end
    alias_method :to_s, :inspect
  end
end
