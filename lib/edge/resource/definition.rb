# frozen_string_literal: true

module Edge
  class Resource
    # How a resource class is declared: which manifest entry it maps to, what
    # readers that gives it, and how a relationship pointing at it finds it
    # again.
    #
    # Extended into Resource rather than written inside it, because declaring a
    # class and being an instance of one are separate concerns that were
    # accumulating in the same place.
    module Definition
      # The manifest key this class maps to: the route name, not the JSON:API
      # type. They differ (docs/release-blockers.md, RB-3).
      #
      # Inherited, like the readers themselves. A subclass — a gateway
      # decorating PaymentDemand, say — keeps every generated reader, so it must
      # keep the metadata that describes them too, or `unknown_attributes`
      # reports the entire attribute set as drift.
      def contract_name = @contract_name || from_superclass(:contract_name)

      def contract_spec = contract_name && Contract.resource(contract_name)

      def json_api_type = contract_spec&.fetch("json_api_type", nil) || contract_name

      # Attribute names the contract knows about, in manifest order.
      def attribute_names = inherited_list(:attribute_names)

      # Relationship names the contract knows about, in manifest order.
      def relationship_names = inherited_list(:relationship_names)

      # Attributes the contract records but which could not be given a reader
      # because the name is already taken — by Object, or by this class. They
      # stay reachable through `#[]`.
      #
      # There is one today: `processor_details` serializes an attribute named
      # `type` (`views/processor_details.ex:15`), which JSON:API 1.1 §5.2
      # forbids precisely because it collides with the resource object's own
      # `type`. So the attribute is read as `detail["type"]`. See
      # docs/release-blockers.md, FU-8.
      #
      # The suite pins this list for every resource in the manifest, so a new
      # collision is a test failure rather than a puzzling nil in someone's
      # production logs.
      def shadowed_attributes = inherited_list(:shadowed_attributes)

      # Relationships whose name is already taken, and which therefore have no
      # generated reader. Reachable through `#relationship(name)` — not through
      # `#[]`, which reads attributes.
      def shadowed_relationships = inherited_list(:shadowed_relationships)

      # Declares the manifest entry, defines the attribute and relationship
      # readers, and registers the class so a relationship pointing here
      # resolves to it.
      def contract(name)
        @contract_name = name.to_s
        spec = Contract.resource(@contract_name)
        raise ArgumentError, "#{@contract_name} is not in contract/manifest.yml" unless spec

        define_attribute_readers(spec["attributes"] || {})
        define_relationship_readers(spec["relationships"] || {})
        # Later declarations win, deliberately: Rails reloads a class under the
        # same name on every request in development, and refusing or warning
        # about the second would make the gem unusable there.
        Resource.registry[@contract_name] = self
      end

      # The class for a manifest resource name.
      #
      # Returns whichever class declared that contract, or — for a name the
      # manifest knows but no class has claimed — one generated from the
      # manifest, so that a relationship resolves to something with readers
      # rather than to an attribute-less base class. A name the manifest does
      # not have falls back to the base class, which can still be read with
      # `#[]`.
      #
      # Keyed by route name rather than by JSON:API type on purpose: a type can
      # belong to another resource entirely (RB-3), so a type registry would
      # hand back a BeneficialOwner full of financial-institution fields.
      def for(name)
        name = name.to_s
        registry[name] || generate(name)
      end

      # One hash for the whole hierarchy. Not `@registry ||= {}`: that is a
      # per-singleton variable, so `PaymentDemand.registry` would be a
      # different, empty hash from the one `contract` writes to, and
      # `PaymentDemand.for("merchants")` would quietly answer with the base
      # class. Eager, so a threaded boot cannot build two of them and lose
      # registrations.
      def registry = REGISTRY

      # Builds one resource from a document's primary data, or nil when the
      # document carried none.
      def from(document, client: nil)
        payload = document.data
        return nil unless payload.is_a?(Hash)

        new(payload, document: document, client: client)
      end

      # Builds the resources in a collection document. Non-Hash entries are
      # skipped rather than raising: a malformed element should cost its own
      # record, not the whole page.
      def list_from(document, client: nil)
        # Not `Array(document.data)`: Kernel#Array turns a Hash into its pairs,
        # so a single-resource document would come back as a list of two-element
        # arrays rather than as nothing.
        return [] unless document.collection?

        document.data.grep(Hash).map { |payload| new(payload, document: document, client: client) }
      end

      # Deliberately not called `inherited`: that is Ruby's own hook for "a
      # subclass was just created", and shadowing it with a different arity
      # breaks subclassing outright.
      def from_superclass(name)
        superclass.public_send(name) if superclass.respond_to?(name)
      end

      private

      def inherited_list(name)
        variable = :"@#{name}"
        instance_variable_get(variable) ||
          instance_variable_set(variable, from_superclass(name)&.dup || [])
      end

      def generate(name)
        return Resource unless Contract.resource(name)

        REGISTRY_LOCK.synchronize do
          registry[name] ||= generated_class(constant_name(name)) do
            Class.new(Resource) { contract(name) }
          end
        end
      end

      # Reuses the constant if it is already there. A registry entry can be
      # removed — a test suite restoring a snapshot, a reload — while the
      # constant survives, and const_set would then warn about redefining it on
      # every subsequent call.
      def generated_class(constant)
        return Generated.const_get(constant) if Generated.const_defined?(constant, false)

        Generated.const_set(constant, yield)
      end

      def constant_name(name) = name.split("_").map(&:capitalize).join

      # A relationship reader returns an Edge::Relationship, always — never the
      # related record and never nil. The API sends resource linkage for only
      # one of the three relationship shapes it has (FU-11), so a reader that
      # returned "the record, or an identifier, or nothing" would have a return
      # type the caller could not predict from the code. `#fetch` is the
      # uniform answer, and it is spelled as the request it is.
      def define_relationship_readers(relationships)
        relationships.each_key do |name|
          relationship_names << name
          next shadowed_relationships << name if reader_taken?(name)

          define_method(name) { relationship(name) }
        end
      end

      def define_attribute_readers(attributes)
        attributes.each_key do |name|
          attribute_names << name
          next shadowed_attributes << name if reader_taken?(name)

          define_method(name) { self[name] }
        end
      end

      # `respond_to?` is not enough: it misses private methods, and defining
      # `send` or `freeze` over one would break the object in ways that surface
      # a long way from here.
      def reader_taken?(name)
        return true unless name.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)

        method_defined?(name) || private_method_defined?(name)
      end
    end
  end
end
