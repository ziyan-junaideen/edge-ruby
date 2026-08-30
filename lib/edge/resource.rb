# frozen_string_literal: true

module Edge
  # Base class for the API's resources.
  #
  # Two properties matter more than convenience here:
  #
  # **Known readers are generated from the contract, and only from the
  # contract.** A subclass declares which manifest entry it maps to, and gets a
  # reader for each attribute the manifest records. There is no `method_missing`
  # fallback, so `demand.amont_cents` raises NoMethodError instead of returning
  # nil and booking a payment of nothing.
  #
  # **Unknown fields survive.** The server may add an attribute before this gem
  # knows about it, and a client that drops what it does not recognise makes
  # that invisible. Anything the payload carries is reachable through `#[]`,
  # listed by `#unknown_attributes`, and present verbatim in `#raw`.
  #
  # Values are returned exactly as the server sent them — timestamps included,
  # as ISO 8601 strings. Coercing them would mean returning a Time when parsing
  # succeeds and a String when it does not, and a reader whose class depends on
  # the data is worse than one that is merely inconvenient.
  class Resource
    class << self
      # The manifest key this class maps to: the route name, not the JSON:API
      # type. They differ (docs/release-blockers.md, RB-3).
      #
      # Inherited, like the readers themselves. A subclass — a gateway
      # decorating PaymentDemand, say — keeps every generated reader, so it
      # must keep the metadata that describes them too, or
      # `unknown_attributes` reports the entire attribute set as drift.
      def contract_name = @contract_name || from_superclass(:contract_name)

      # Attribute names the contract knows about, in manifest order.
      def attribute_names
        @attribute_names ||= from_superclass(:attribute_names)&.dup || []
      end

      # Attributes the contract records but which could not be given a reader
      # because the name is already taken — by Object, or by this class. They
      # stay reachable through `#[]`.
      #
      # There is one today: `processor_details` serializes an attribute named
      # `type` (`views/processor_details.ex:15`), which JSON:API 1.1 §5.2
      # forbids precisely because it collides with the resource object's own
      # `type`. So `ProcessorDetail#type` is the JSON:API type, and the
      # attribute is read as `detail["type"]`. See docs/release-blockers.md,
      # FU-8.
      #
      # The suite pins this list for every resource in the manifest, so a new
      # collision is a test failure here rather than a puzzling nil in
      # someone's production logs.
      def shadowed_attributes
        @shadowed_attributes ||= from_superclass(:shadowed_attributes)&.dup || []
      end

      def json_api_type = contract_spec&.fetch("json_api_type", nil) || contract_name

      # Deliberately not called `inherited`: that is Ruby's own hook for "a
      # subclass was just created", and shadowing it with a different arity
      # breaks subclassing outright.
      def from_superclass(name)
        superclass.public_send(name) if superclass.respond_to?(name)
      end

      def contract_spec = contract_name && Contract.resource(contract_name)

      # Declares the manifest entry and defines the attribute readers.
      def contract(name)
        @contract_name = name.to_s
        spec = Contract.resource(@contract_name)
        raise ArgumentError, "#{@contract_name} is not in contract/manifest.yml" unless spec

        define_attribute_readers(spec["attributes"] || {})
      end

      # Builds one resource from a document's primary data, or nil when the
      # document carried none. A `null` data member is a real answer — an unset
      # to-one relationship — and is reported as nil rather than as an error.
      def from(document)
        payload = document.data
        return nil unless payload.is_a?(Hash)

        new(payload, document: document)
      end

      # Builds the resources in a collection document. Non-Hash entries are
      # skipped rather than raising: a malformed element should cost its own
      # record, not the whole page.
      def list_from(document)
        # Not `Array(document.data)`: Kernel#Array turns a Hash into its pairs,
        # so a single-resource document would come back as a list of two-element
        # arrays rather than as nothing.
        return [] unless document.collection?

        document.data.grep(Hash).map { |payload| new(payload, document: document) }
      end

      private

      def define_attribute_readers(attributes)
        attributes.each_key do |name|
          attribute_names << name

          if reader_taken?(name)
            shadowed_attributes << name
            next
          end

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

    # The document this resource was parsed out of, when it came from one.
    # Carries the `included` records and the top-level `links` and `meta`.
    attr_reader :document

    # Exactly what the server sent for this resource, unredacted by design.
    # Everything else on this class is filtered; this is the escape hatch for
    # when you need the truth, and the one place a secret can still be read.
    attr_reader :raw

    def initialize(payload, document: nil)
      @raw = payload.is_a?(Hash) ? payload : {}
      @document = document
    end

    def id = raw["id"]

    # The type the server reported. Not necessarily this class's route name —
    # see RB-3, where one endpoint reports another resource's type.
    def type = raw["type"]

    def attributes = @attributes ||= (raw["attributes"].is_a?(Hash) ? raw["attributes"] : {})

    def relationships
      @relationships ||= (raw["relationships"].is_a?(Hash) ? raw["relationships"] : {})
    end

    def links = @links ||= (raw["links"].is_a?(Hash) ? raw["links"] : {})

    def meta = @meta ||= (raw["meta"].is_a?(Hash) ? raw["meta"] : {})

    # Any attribute, known to the contract or not, by string or symbol.
    def [](name) = attributes[name.to_s]

    def key?(name) = attributes.key?(name.to_s)

    # Attributes the server sent that the contract does not describe. Not an
    # error — it is how a new field announces itself — but worth being able to
    # see, and what the drift check reads.
    def unknown_attributes = attributes.keys - self.class.attribute_names

    def identifier
      JSONAPI::Identifier.from(raw)
    end

    # The attributes, as a shallow copy: keys can be added and removed, but
    # nested values still belong to the frozen document and cannot be changed
    # in place.
    #
    # Identity is deliberately not folded in. `type` is an attribute on at
    # least one resource (see `shadowed_attributes`), so merging the JSON:API
    # `type` over the top would silently destroy real data on exactly the
    # resource where it is hardest to notice.
    def to_h = attributes.dup

    # Identity is the record, not the object: the same customer parsed from two
    # responses is the same customer. Class is part of it so that two resources
    # sharing a type string — which RB-3 makes possible — do not compare equal.
    def ==(other)
      other.instance_of?(self.class) && other.id == id && other.type == type && !id.nil?
    end
    alias eql? ==

    def hash = [self.class, type, id].hash

    # Never prints attribute values. A resource can hold a webhook signing key
    # or a national ID number, and `inspect` reaches consoles, `pp`, and every
    # exception reporter that renders local variables.
    def inspect = "#<#{self.class.name} id=#{id.inspect} type=#{type.inspect}>"
    alias to_s inspect
  end
end
