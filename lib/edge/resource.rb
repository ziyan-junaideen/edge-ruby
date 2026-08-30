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
    # Classes built from the manifest for resources nothing else has claimed.
    # Named rather than anonymous so that `inspect` and backtraces say what
    # they are.
    Generated = Module.new

    # Mutable by design: this is the live map from manifest name to class, and
    # `contract` writes to it as classes load.
    REGISTRY = {} # rubocop:disable Style/MutableConstant
    REGISTRY_LOCK = Monitor.new
    private_constant :REGISTRY_LOCK

    extend Definition

    # The document this resource was parsed out of, when it came from one.
    # Carries the `included` records and the top-level `links` and `meta`.
    attr_reader :document

    # Exactly what the server sent for this resource, unredacted by design.
    # Everything else on this class is filtered; this is the escape hatch for
    # when you need the truth, and the one place a secret can still be read.
    attr_reader :raw

    # The client this resource came from, used by `Relationship#fetch`. Never
    # used to fetch anything implicitly.
    attr_reader :client

    def initialize(payload, document: nil, client: nil)
      @raw = payload.is_a?(Hash) ? payload : {}
      @document = document
      @client = client
    end

    def id = raw["id"]

    # The type the server reported. Not necessarily this class's route name —
    # see RB-3, where one endpoint reports another resource's type.
    def type = raw["type"]

    def attributes = @attributes ||= (raw["attributes"].is_a?(Hash) ? raw["attributes"] : {})

    def relationships
      @relationships ||= (raw["relationships"].is_a?(Hash) ? raw["relationships"] : {})
    end

    # One relationship by name, whether or not the contract knows about it.
    # Always an Edge::Relationship, even for a name the server did not send —
    # asking about a relationship that is absent is not an error, and the
    # answer is a relationship that reports itself as unloaded.
    def relationship(name)
      (@relationship_objects ||= {})[name.to_s] ||=
        Relationship.new(name, relationships[name.to_s], owner: self)
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
