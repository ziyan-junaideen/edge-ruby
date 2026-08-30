# frozen_string_literal: true

module Edge
  module JSONAPI
    # One JSON:API error object. The API returns these for most failures, but
    # not all — see Edge::APIError for the plain-text cases.
    class ErrorObject
      ATTRIBUTES = %w[id status code title detail].freeze

      ATTRIBUTE_POINTER = "/data/attributes/"

      attr_reader :id, :status, :code, :title, :detail, :source, :meta

      def self.from(document)
        Array(document["errors"]).map { |error| new(error) }
      end

      def initialize(payload)
        payload = {} unless payload.is_a?(Hash)
        ATTRIBUTES.each do |name|
          instance_variable_set(:"@#{name}", Redaction.scrub(payload[name]))
        end
        # Scrubbed like the scalars: `meta` in particular is server-controlled
        # and has no defined shape, so it can carry anything.
        @source = Redaction.scrub_data(payload["source"].is_a?(Hash) ? payload["source"] : {})
        @meta = Redaction.scrub_data(payload["meta"].is_a?(Hash) ? payload["meta"] : {})
      end

      # A JSON Pointer at the offending member, e.g. "/data/attributes/amount_cents".
      def pointer = source["pointer"]

      # The query parameter at fault, e.g. "page[limit]".
      def parameter = source["parameter"]

      # The attribute name a pointer refers to, or nil when the error is not
      # about a single attribute.
      def attribute
        return nil unless pointer.to_s.start_with?(ATTRIBUTE_POINTER)

        # Not `split("/").last`: String#split drops trailing empty fields, so
        # a bare "/data/attributes/" would yield "attributes" and invent a form
        # field that does not exist.
        name = pointer[ATTRIBUTE_POINTER.length..].to_s
        name.empty? ? nil : name.split("/").first
      end

      def to_s = [title, detail].compact.join(": ")

      def inspect
        "#<#{self.class.name} status=#{status.inspect} code=#{code.inspect} " \
          "pointer=#{pointer.inspect}>"
      end
    end
  end
end
