# frozen_string_literal: true

require "yaml"

module Edge
  # Reads `contract/manifest.yml`, the generated description of what the API
  # exposes. Shipping it in the gem and reading it at runtime is deliberate:
  # the redaction list in particular must come from the same place the contract
  # does, or the two drift and secrets start reaching logs.
  #
  # See contract/PROVENANCE.md for how the manifest is produced and what it
  # can and cannot assert.
  module Contract
    PATH = File.expand_path("../../contract/manifest.yml", __dir__)

    class << self
      def manifest
        @manifest ||= YAML.safe_load_file(PATH, freeze: true)
      end

      def resources = manifest.fetch("resources")

      def resource(type) = resources[type.to_s]

      # Field names that must never be printed for a given resource type.
      def sensitive_fields(type)
        resource(type)&.fetch("sensitive_fields", nil) || []
      end

      # Field and header names redacted wherever they appear, regardless of
      # which resource they belong to.
      def always_redact = manifest.fetch("always_redact", [])

      # Every segment the API's own URLs are built from: route names,
      # relationship names, custom actions and the version prefixes.
      #
      # Anything else in a path is an identifier. Deriving that from the
      # contract beats guessing at it — a length heuristic once rewrote
      # `/v2/personal_identifications` to `/v2/:id`.
      def path_segments
        @path_segments ||= begin
          words = ["relationships"] + resources.keys +
                  resources.values.flat_map { |spec| segments_for(spec) }
          words.reject { |word| word.empty? || word == "{id}" }.uniq.freeze
        end
      end

      # Every sensitive field across every resource, plus the global list. Used
      # when the resource type is not known — an error body, a log line.
      def all_sensitive_fields
        @all_sensitive_fields ||=
          (always_redact + resources.flat_map { |_, spec| spec["sensitive_fields"] || [] })
          .map(&:downcase).uniq.freeze
      end

      private

      def segments_for(spec)
        (spec["relationships"] || {}).keys +
          (spec["custom_actions"] || []).flat_map { |action| action["path"].to_s.split("/") } +
          [spec["api_version"]].compact
      end
    end
  end
end
