# frozen_string_literal: true

module Edge
  module JSONAPI
    # A parsed JSON:API top-level document.
    #
    # Its job is to be honest about a body that may be almost anything: the API
    # returns `data` as an object, as an array, as `null`, or not at all, and a
    # proxy can return something that is not a JSON:API document while still
    # claiming a 200. Nothing here raises on a shape it did not expect — a
    # malformed body yields a document that reports itself as empty, and the
    # untouched body stays available on `#raw` for whoever has to work out why.
    class Document
      attr_reader :raw

      # Note that this freezes the response's parsed body in place; see
      # `#initialize`. That is usually what you want for a server response, but
      # it is visible to anything else holding `response.data`.
      def self.from_response(response) = new(response.data)

      # Freezes the body through, once, at the boundary — **in place**, not on
      # a copy. Resources built from this document alias the very same hashes
      # (a record in `included` is shared with every relationship pointing at
      # it), so without this a caller mutating one resource's `raw` would
      # silently rewrite another's. Deep-copying every response body instead
      # would cost a full traversal on the hot path for a guarantee nobody
      # asked for, so the argument is frozen and this says so.
      def initialize(body)
        @raw = deep_freeze(body.is_a?(Hash) ? body : {})
      end

      # The primary data: a Hash for a single resource, an Array for a
      # collection, nil when the document carried none. `null` data is a
      # legitimate answer for a to-one relationship that is unset, and is not
      # the same as an absent `data` member.
      def data = raw["data"]

      def collection? = data.is_a?(Array)

      # True when the document has a `data` member at all, whatever its value.
      # Distinguishes "this record has no payer" from "this body is not a
      # resource document".
      def data? = raw.key?("data")

      # Every member below is type-checked rather than trusted. This class
      # promises not to raise on a shape it did not expect, and a top-level
      # guard on `raw` alone does not deliver that: `{"included": 42}` is a
      # Hash, and `42.length` inside `#inspect` would raise while an error
      # reporter was formatting the very document it was trying to describe.
      def included = array_member("included")

      def links = hash_member("links")

      def meta = hash_member("meta")

      # The `jsonapi` member, which carries the server's declared version.
      def jsonapi = hash_member("jsonapi")

      def errors = array_member("errors")

      # A named link as a string, or nil. Per JSON:API a link may be a bare
      # string or an object with an `href`; both are read.
      def link(name)
        value = links[name.to_s]
        case value
        when String then value
        when Hash then value["href"]
        end
      end

      # The record from `included` matching an identifier, or nil when the
      # server did not send it. Indexed once: a document with 200 line items
      # and 200 lookups is otherwise quadratic.
      def find_included(identifier)
        return nil unless identifier

        index[[identifier.type, identifier.id]]
      end

      def empty? = raw.empty?

      # Redacted: a document can hold webhook signing secrets and KYC
      # identifiers, and `inspect` output reaches consoles and error reporters.
      # `#raw` is the deliberate exception, and says so.
      def inspect
        shape = collection? ? "data=[#{data.length}]" : "data=#{data.class}"
        "#<#{self.class.name} #{shape} included=#{included.length}>"
      end
      alias to_s inspect

      private

      def hash_member(name)
        value = raw[name]
        value.is_a?(Hash) ? value : {}
      end

      def array_member(name)
        value = raw[name]
        value.is_a?(Array) ? value : []
      end

      def index
        @index ||= included.each_with_object({}) do |record, result|
          next unless record.is_a?(Hash)

          result[[record["type"].to_s, record["id"].to_s]] ||= record
        end
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |nested| deep_freeze(nested) }.freeze
        when Array then value.each { |item| deep_freeze(item) }.freeze
        else value.freeze
        end
      end
    end
  end
end
