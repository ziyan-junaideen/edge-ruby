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

      # Names the member at fault, because the API frequently sends a batch of
      # errors whose text is identical. Creating a payment demand without the
      # 3DS fields answers with ten errors, every one of them reading
      # "can't be blank" and every one pointing somewhere different. A message
      # that repeats the title ten times says nothing the first one did not;
      # the pointer is the only part that tells the caller what to fix.
      #
      # Empty text still yields an empty string, so that an error carrying only
      # a `code` continues to fall back to the body excerpt in APIError.
      def to_s
        text = [title, detail].compact.map(&:to_s).reject(&:empty?).join(": ")
        return "" if text.empty?

        # `to_s` rather than truthiness: a server that sends `"pointer": ""`
        # would otherwise render `": can't be blank"`.
        label = [attribute, parameter, pointer].compact.map(&:to_s).find { |v| !v.empty? }
        label ? "#{label}: #{text}" : text
      end

      def inspect
        "#<#{self.class.name} status=#{status.inspect} code=#{code.inspect} " \
          "pointer=#{pointer.inspect}>"
      end
    end
  end
end
