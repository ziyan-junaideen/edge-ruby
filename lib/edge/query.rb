# frozen_string_literal: true

module Edge
  # Builds the query parameters for a JSON:API collection request: `filter`,
  # `sort`, `include`, `fields` and `page`.
  #
  # This exists because the server's parser is silent about what it cannot use.
  # A filter it fails to resolve is **dropped**, not rejected (see
  # docs/release-blockers.md, FU-2), and production does not paginate — so one
  # mistyped filter turns a narrow lookup into a full-table fetch that still
  # returns 200. Every rule enforced here was read off the server's own parser
  # (`phoenix_jsonapi/jsonapi_parser_plug.ex`, `phoenix_jsonapi/parameters.ex`),
  # and each marks a case where the request the caller wrote is not the request
  # the server would run.
  #
  # Two levels of checking:
  #
  #   - Always on: rules that follow from the shape of the parser rather than
  #     from any field list, so they hold whatever the manifest says. Those live
  #     in Query::Filters.
  #   - `strict: true` with a `resource:`: field and relationship names are
  #     checked against `contract/manifest.yml` by Query::PathChecker. Opt-in,
  #     because a manifest that has fallen behind the server would otherwise
  #     reject a field that really does exist.
  #
  # `params:` is the escape hatch. It is sent as given, for the cases this class
  # refuses or does not know about.
  #
  #   Edge::Query.encode(
  #     filter:  { "payer.email" => "ada@example.com", amount_cents: { gte: 1000 } },
  #     include: %i[payer payment_method],
  #     sort:    ["-created_at"]
  #   )
  #   # => {"filter[payer.email]"     => "ada@example.com",
  #   #     "filter[amount_cents_gte]" => "1000",
  #   #     "include"                  => "payer,payment_method",
  #   #     "sort"                     => "-created_at"}
  class Query
    # Ordered as the server orders them (`parameters.ex:270`), longest first, so
    # `amount_cents_gte` resolves to `gte` rather than to `gt`.
    COMPARISON_SUFFIXES = { "_gte" => :gte, "_lte" => :lte, "_gt" => :gt, "_lt" => :lt }.freeze

    OPERATORS = { eq: "", gt: "_gt", gte: "_gte", lt: "_lt", lte: "_lte" }.freeze

    # `"null"` and `"NULL"` are cast to nil and compiled to `IS NULL`
    # (`parameters.ex:634`). It follows that the literal string "null" cannot be
    # filtered for at all; `nil` is spelled this way deliberately.
    NULL = "null"

    include Values

    class << self
      # The common case: build and encode in one step.
      def encode(**) = new(**).to_params
    end

    def initialize(filter: nil, sort: nil, include: nil, fields: nil, page: nil, params: nil,
                   resource: nil, strict: false)
      @filter = filter
      @sort = sort
      @include = include
      @fields = fields
      @page = page
      @params = params
      @resource = resource&.to_s
      @checker = PathChecker.new(@resource) if strict && @resource

      return unless strict && @resource.nil?

      raise ArgumentError, "strict: true needs a resource: to check names against"
    end

    # A flat `String => String` hash, ready to hand to Faraday, which escapes
    # the brackets. That is the standard form and what the server's parser
    # reads.
    def to_params
      params = Filters.new(@filter, checker: @checker).to_params
      params.merge!(list_param("include", @include, check: :check_include))
      params.merge!(list_param("sort", @sort, check: :check_sort))
      params.merge!(fields_params)
      params.merge!(page_params)

      # Merged last so the escape hatch always wins, and passed through
      # untouched: it exists precisely for what the rules above refuse.
      params.merge!(stringify(@params)) if @params
      params
    end

    def empty? = to_params.empty?

    private

    # `include`, `sort` and each `fields[type]` are comma-separated lists
    # (`jsonapi_parser_plug.ex:145`). Descending sort is a leading `-` and a
    # dotted path is a relationship chain; both are passed through as written.
    def list_param(name, value, check: nil)
      items = list_items(value)
      return {} if items.empty?

      items.each { |item| @checker.public_send(check, item) } if check && @checker
      { name => items.join(",") }
    end

    def list_items(value)
      return [] if value.nil?

      (value.is_a?(Array) ? value : [value]).map { |item| scalar(item) }.reject(&:empty?)
    end

    def fields_params
      return {} unless @fields

      pairs(@fields).each_with_object({}) do |(type, names), result|
        # Keyed by JSON:API type, not by route name. The two differ for
        # financial_institutions (RB-3), where the type belongs to another
        # resource entirely, so neither spelling selects fields the way the
        # endpoint's name suggests. Left unchecked for that reason.
        result.merge!(list_param("fields[#{type}]", names))
      end
    end

    # Passed through as a plain hash. The cursor contract is not merged and
    # production ignores these entirely (docs/pagination.md), so naming the keys
    # here would promise a shape the server does not yet honour.
    def page_params
      return {} unless @page

      pairs(@page).to_h { |key, value| ["page[#{key}]", scalar(value)] }
    end
  end
end
