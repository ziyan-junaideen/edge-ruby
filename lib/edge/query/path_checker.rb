# frozen_string_literal: true

module Edge
  class Query
    # Checks a dotted field path against `contract/manifest.yml`.
    #
    # `filter[merchant.business_name]`, `include=payment_demands.payer` and
    # `sort=-merchant.business_name` are all the same shape: a chain of
    # relationships ending in a field. What differs is only what the last
    # segment may be —
    #
    #   :relationship — `include`, which can only name relationships
    #   :attribute    — `sort`, and any filter carrying a comparison operator
    #   :either       — a plain filter, which also accepts a relationship,
    #                   matching a belongs-to by id (`parameters.ex:374`)
    #
    # Used by Query in strict mode. Kept separate because it answers a question
    # — "does this path exist on this resource?" — that has nothing to do with
    # encoding, and because the resource layer needs the same answer.
    class PathChecker
      def initialize(resource)
        @resource = resource.to_s
      end

      def check_include(path)
        walk(@resource, path.split("."), "include=#{path}", :relationship)
      end

      # A leading `-` is the direction, not part of the path.
      def check_sort(field)
        walk(@resource, field.delete_prefix("-").split("."), "sort=#{field}", :attribute)
      end

      # A comparison filter must end at an attribute: the server refuses any
      # operator but equality on a relationship (`parameters.ex:405`), and
      # drops the filter rather than saying so.
      def check_filter(path, label, comparison: false)
        walk(@resource, path.split("."), label, comparison ? :attribute : :either)
      end

      private

      # Stops without complaint as soon as a hop cannot be resolved: the
      # manifest is generated and records its own gaps, and refusing a request
      # over a field the extractor merely failed to see would be worse than
      # sending it.
      def walk(resource_name, segments, label, terminal)
        spec = Contract.resource(resource_name)
        return if spec.nil? || segments.empty?

        field, *rest = segments
        return relationship_filter!(spec, field, label, resource_name) if
          relationship_filter?(spec, field, rest, terminal)

        return if identity_segment?(field, rest, terminal)
        return terminal_segment!(spec, field, label, resource_name, terminal) if rest.empty?

        walk(related_resource!(spec, field, label, resource_name), rest, label, terminal)
      end

      # No resource lists `id` among its attributes; it is the identity. Only
      # as the last segment, though — `filter[id.anything]` looks for a
      # relationship called `id`, finds none, and is dropped — and never for an
      # `include`, which must name a relationship.
      def identity_segment?(field, rest, terminal)
        field == "id" && rest.empty? && terminal != :relationship
      end

      # `filter[payer]` and `filter[payer.id]` are the same request: both go to
      # `relationship_filter/5` (`parameters.ex:374` and `:382`), which matches
      # the related record by the owner's foreign key.
      def relationship_filter?(spec, field, rest, terminal)
        terminal == :either && (rest.empty? || rest == ["id"]) && relationships(spec).key?(field)
      end

      # That path requires an `Ecto.Association.BelongsTo` (`parameters.ex:417`);
      # every other association falls through to `:error` at `:425` and the
      # filter is dropped. The manifest cannot see the Ecto association type,
      # but it does record cardinality, and a to-many relationship is never a
      # belongs-to — so this catches the 17 to-many relationships for certain,
      # and leaves the rarer has-one case to the server.
      def relationship_filter!(spec, field, label, resource_name)
        return if relationships(spec)[field]["cardinality"] != "many"

        raise ArgumentError,
              "#{label} filters on #{field.inspect}, which is a to-many relationship on " \
              "#{resource_name}. The API can only filter across a belongs-to, and drops the " \
              "rest — returning the whole collection. Filter #{field} itself and follow the " \
              "relationship the other way instead."
      end

      def terminal_segment!(spec, field, label, resource_name, terminal)
        return related_resource!(spec, field, label, resource_name) if terminal == :relationship
        return if attributes(spec).key?(field)

        raise ArgumentError,
              "#{label} names #{field.inspect}, which #{resource_name} does not have " \
              "#{as_a(terminal)}. #{suggestion(spec, field, terminal)}The API drops what it " \
              "cannot resolve, so this would quietly return something other than what was " \
              "asked for."
      end

      def as_a(terminal) = terminal == :attribute ? "as an attribute" : "as a field"

      def related_resource!(spec, field, label, resource_name)
        relationship = relationships(spec)[field]
        unless relationship
          raise ArgumentError,
                "#{label} traverses #{field.inspect}, which is not a relationship on " \
                "#{resource_name}. #{suggestion(spec, field, :relationship)}"
        end

        # Resolved through the view module name rather than the JSON:API type:
        # a view can report a type belonging to another resource entirely
        # (docs/release-blockers.md, RB-3), and the module name does not lie.
        snake_case(relationship["view"])
      end

      # Ruby ships did_you_mean, and its spell checker is what NoMethodError
      # itself uses. Borrowing it means "emial" suggests "email" rather than
      # the nothing a prefix match would find — and a mistyped filter is
      # exactly the case where the caller gets no other feedback at all.
      def suggestion(spec, field, terminal)
        return "" unless defined?(DidYouMean::SpellChecker)

        near = DidYouMean::SpellChecker.new(dictionary: dictionary(spec, terminal)).correct(field)
        near.empty? ? "" : "Did you mean #{near.first(3).map(&:inspect).join(", ")}? "
      end

      # Only names that would have been accepted in this position, so the
      # suggestion is never something that would fail for a different reason.
      def dictionary(spec, terminal)
        case terminal
        when :relationship then relationships(spec).keys
        when :attribute then attributes(spec).keys
        else attributes(spec).keys + relationships(spec).keys
        end
      end

      def attributes(spec) = spec["attributes"] || {}

      def relationships(spec) = spec["relationships"] || {}

      def snake_case(name) = name.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
    end
  end
end
