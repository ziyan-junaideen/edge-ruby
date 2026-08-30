# frozen_string_literal: true

require "date"
require "time"

module Edge
  class Query
    # Turning Ruby values into the strings the server's parser expects.
    #
    # Shared by Query and Query::Filters because both write into the same query
    # string and a value that encoded one way in `filter[created_at_gte]` and
    # another in `page[after]` would be a bug nobody would think to look for.
    module Values
      private

      def scalar(value)
        case value
        when nil then NULL
        # DateTime is a Date, so both must be matched before it.
        when Time, DateTime, Date then value.iso8601
        else value.to_s
        end
      end

      # What `String.trim/1` does to every filter value before it is cast
      # (`parameters.ex:615` and `:629`). Ruby's own `String#strip` is not the
      # same function: it removes ASCII whitespace and NUL only, so a
      # non-breaking space — which a browser paste produces routinely — looks
      # like content here and is trimmed away to nothing there.
      def trim(value) = value.to_s.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")

      def pairs(value)
        raise ArgumentError, "expected a Hash, got #{value.class}" unless value.is_a?(Hash)

        value.to_a
      end

      def stringify(hash) = pairs(hash).to_h { |key, value| [key.to_s, value] }
    end
  end
end
