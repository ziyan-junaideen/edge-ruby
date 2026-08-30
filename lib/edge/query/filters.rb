# frozen_string_literal: true

module Edge
  class Query
    # Encodes the `filter[…]` parameters, and refuses the ones the server would
    # accept without honouring.
    #
    # This is where the domain knowledge lives. Read it to know what the API
    # will actually do with a filter, because it will not tell you: an
    # unresolvable filter is dropped and the request still returns 200, over an
    # unpaginated collection. Every rule cites the line of
    # `phoenix_jsonapi/parameters.ex` it was read from.
    class Filters
      include Values

      # Cast to nil and compiled to `IS NULL` (`parameters.ex:635`), after the
      # value has already been trimmed. Both spellings, and only these two.
      NULL_LITERALS = %w[null NULL].freeze

      def initialize(filter, checker: nil)
        @filter = filter
        @checker = checker
      end

      def to_params
        return {} unless @filter

        pairs(@filter).flat_map { |key, value| expand(key, value) }
                      .each_with_object({}) do |(path, value), result|
          name = "filter[#{path}]"
          reject_duplicate!(result, name, path)
          result[name] = encode(path, value)
        end
      end

      private

      # `{ amount_cents: { gte: 1000 } }` and `{ "amount_cents_gte" => 1000 }`
      # are the same request. The first form is checkable, so it is the one
      # worth offering; the second is what the wire looks like and stays
      # supported.
      def expand(key, value)
        reject_blank_name!(key)
        return [[key.to_s, value]] unless value.is_a?(Hash)

        value.map do |operator, operand|
          suffix = OPERATORS.fetch(operator.to_sym) do
            raise ArgumentError, "unknown filter operator #{operator.inspect} on #{key}; " \
                                 "expected one of #{OPERATORS.keys.join(", ")}"
          end
          ["#{key}#{suffix}", operand]
        end
      end

      # `filter[]=x` is not an empty-named filter, it is a list: Plug parses it
      # as `%{"filter" => ["x"]}`, and `filters/1`
      # (`jsonapi_parser_plug.ex:58`) destructures a two-tuple, so the request
      # raises rather than being ignored. `filter: { params[:field] => query }`
      # with a blank field is the ordinary way to arrive here.
      def reject_blank_name!(key)
        return unless trim(key).empty?

        raise ArgumentError,
              "a filter name is blank, which would send `filter[]=` — the API parses that as a " \
              "list and its parser raises on it. Omit the filter instead."
      end

      # Two spellings of one filter would otherwise collide in the hash and the
      # loser would vanish without trace — the same silent-drop failure this
      # class exists to prevent, just committed on our side of the wire.
      def reject_duplicate!(params, name, path)
        return unless params.key?(name)

        raise ArgumentError, "filter[#{path}] was given twice; only one value would be sent."
      end

      def encode(path, value)
        values = value.is_a?(Array) ? value : [value]
        encoded = values.map { |item| encode_value(path, item) }

        validate!(path, encoded)
        encoded.join(",")
      end

      # A comma is the value separator and there is no escape for it
      # (`parameters.ex:612` splits every string value on ","). A value that
      # contains one silently becomes two values OR'd together, which is not
      # what the caller wrote and cannot be expressed any other way.
      def encode_value(path, value)
        encoded = scalar(value)
        return encoded unless encoded.include?(",")

        raise ArgumentError,
              "filter[#{path}] value contains a comma, which the API always reads as a value " \
              "separator — there is no escape for it. Pass an Array to match any of several " \
              "values, or use params: to send the query as-is."
      end

      def validate!(path, encoded)
        reject_blank_values!(path, encoded)
        suffix, operator = COMPARISON_SUFFIXES.find { |candidate, _| path.end_with?(candidate) }
        validate_comparison!(path, encoded, suffix, operator) if operator

        @checker&.check_filter(strip_operator(path), "filter[#{path}]", comparison: !operator.nil?)
      end

      # A blank value is skipped (`parameters.ex:632`). Skip them all and the
      # value list is empty, which drops the filter (`:569`) — and the request
      # succeeds, returning every record, because production does not paginate.
      # An empty search box must not fetch the whole table.
      def reject_blank_values!(path, encoded)
        blank = encoded.count { |value| trim(value).empty? }
        return if blank.zero? && !encoded.empty?

        raise ArgumentError, blank_message(path, blank, encoded.length)
      end

      def blank_message(path, blank, total)
        return <<~MESSAGE.tr("\n", " ").strip if blank < total
          filter[#{path}] has #{blank} blank value(s) among #{total}. The API discards a blank
          value, so this would match on fewer values than were asked for. Remove them from the
          list.
        MESSAGE

        <<~MESSAGE.tr("\n", " ").strip
          filter[#{path}] is empty. The API ignores an empty filter rather than matching nothing,
          so this would return the entire collection. Omit the filter, or pass nil to match
          records whose #{path} is null.
        MESSAGE
      end

      def validate_comparison!(path, encoded, suffix, operator)
        reject_traversing_comparison!(path, operator)
        reject_id_comparison!(path, suffix)

        # Trimmed before the null check because the server trims first: a
        # padded " null " and an upper-case "NULL" both become nil, and
        # `ensure_operator_values` (`parameters.ex:580`) then drops the filter.
        return if encoded.length == 1 && !NULL_LITERALS.include?(trim(encoded.first))

        raise ArgumentError,
              "filter[#{path}] needs exactly one non-null value: #{operator} is a single " \
              "boundary, and the API drops the filter otherwise."
      end

      # The operator is only stripped from a single-segment key
      # (`parameters.ex:272`). On a dotted path the whole last segment is read
      # as a field name, no such field exists, and the filter is dropped.
      def reject_traversing_comparison!(path, operator)
        return unless path.include?(".")

        raise ArgumentError,
              "filter[#{path}] applies #{operator} across a relationship, which the API " \
              "supports only on a resource's own attributes. It would be read as a field " \
              "named #{path.split(".").last.inspect}, not found, and dropped."
      end

      # `id` accepts equality only (`parameters.ex:358`).
      def reject_id_comparison!(path, suffix)
        return unless path.delete_suffix(suffix) == "id"

        raise ArgumentError,
              "filter[#{path}] is not supported: id can only be compared for equality."
      end

      def strip_operator(path)
        suffix = COMPARISON_SUFFIXES.keys.find { |candidate| path.end_with?(candidate) }
        suffix ? path.delete_suffix(suffix) : path
      end
    end
  end
end
