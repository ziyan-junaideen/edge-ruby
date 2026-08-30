# frozen_string_literal: true

module Edge
  # Parses an Edge API key into the two facts a client needs: which mode it
  # addresses, and whether it is safe to use from a server.
  #
  # Keys are minted as `ept_<schema>_<context><base58>` where `schema` is
  # `live` or `sandbox` and `context` is the first character of the token's
  # context, `b` for browser (publishable) or `s` for secret (confidential).
  #
  # The character immediately after the mode is easy to misread as part of the
  # random body — the Elixir SDK's own README shows `ept_sandbox_sQsnYGFo...`,
  # where that `s` is the context marker. A parser that misses it cannot tell a
  # publishable key from a secret one.
  #
  # Anything that does not match is not an error. OAuth bearer tokens
  # authenticate too, and this client must not refuse a credential it simply
  # does not recognise, nor guess a mode for it.
  class ApiKey
    FORMAT = /\Aept_(?<mode>live|sandbox)_(?<context>[bs])(?<body>[1-9A-HJ-NP-Za-km-z]+)\z/

    CONTEXTS = { "b" => :browser, "s" => :secret }.freeze

    attr_reader :mode, :kind

    # Returns an ApiKey when the string is a recognisable Edge key, or nil when
    # it is a credential of some other shape.
    def self.parse(value)
      match = FORMAT.match(value.to_s)
      return nil unless match

      new(mode: match[:mode].to_sym, kind: CONTEXTS.fetch(match[:context]))
    end

    def initialize(mode:, kind:)
      @mode = mode
      @kind = kind
    end

    def browser? = kind == :browser
    def secret? = kind == :secret
    def live? = mode == :live
    def sandbox? = mode == :sandbox

    # Never interpolates the key itself.
    def inspect = "#<#{self.class.name} mode=#{mode} kind=#{kind}>"
    alias to_s inspect
  end
end
