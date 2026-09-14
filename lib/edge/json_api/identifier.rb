# frozen_string_literal: true

module Edge
  module JSONAPI
    # A JSON:API resource identifier: the `{"type", "id"}` pair the server uses
    # to point at a record without sending it.
    #
    # This is what a relationship yields when the response did not carry the
    # related record — that is, when the caller did not ask for it with
    # `include:`. It is deliberately not a lazy proxy: fetching it is an
    # explicit `#fetch`, added in the resource layer, so that reading an
    # attribute can never turn into an HTTP request nobody asked for. A getter
    # that silently issues a GET is how a loop over 500 orders becomes 500
    # round trips.
    class Identifier
      EMPTY_META = {}.freeze
      private_constant :EMPTY_META

      attr_reader :type, :id, :meta

      def self.from(payload)
        return nil unless payload.is_a?(Hash) && payload["type"] && payload["id"]

        new(type: payload["type"], id: payload["id"], meta: payload["meta"])
      end

      def initialize(type:, id:, meta: nil)
        # `-str` rather than `str.to_s`: String#to_s returns self, so a mutable
        # argument would be stored by reference and `identifier.type << "_v2"`
        # would change this object's `#hash` after it had been used as a Hash
        # key — leaving the entry unreachable. Freezing the wrapper alone does
        # not prevent that.
        @type = -type.to_s
        @id = -id.to_s
        @meta = meta.is_a?(Hash) ? meta.dup.freeze : EMPTY_META
        freeze
      end

      # Type and id together are the identity; `meta` is annotation and is left
      # out on purpose, so the same record described twice in one document
      # compares equal and de-duplicates in a Set.
      def ==(other)
        other.is_a?(Identifier) && other.type == type && other.id == id
      end
      alias eql? ==

      def hash = [self.class, type, id].hash

      def to_h = { "type" => type, "id" => id }

      def inspect = "#<#{self.class.name} #{type}/#{id}>"
      alias to_s inspect
    end
  end
end
