# frozen_string_literal: true

module Edge
  # One entry from a resource's `relationships` member.
  #
  # **Nothing here performs I/O except `#fetch`, which says so in its name.**
  # That is the whole design. A getter that quietly issues a GET turns a loop
  # over 500 orders into 500 round trips, and does it invisibly.
  #
  # What the Edge API actually sends is narrower than JSON:API allows, and
  # shapes everything below (`phoenix_jsonapi/resource.ex:130-181`):
  #
  #   - A **belongs-to with its foreign key set** is the only case that carries
  #     `data`. That is the only linkage this client ever sees.
  #   - A **to-many** carries `links.self` and no `data` — even when the caller
  #     asked for it with `include:`. The records arrive in the document's
  #     `included`, with nothing tying them to this relationship.
  #   - A **belongs-to with a null foreign key**, and a **has-one**, carry
  #     neither. The `data` member is commented out in the server
  #     (`resource.ex:173-176`).
  #
  # The last two are why `#loaded?` exists and why an absent `data` member is
  # never reported as "no related record": on this API those are the same
  # bytes. See docs/release-blockers.md, FU-11.
  class Relationship
    attr_reader :name, :raw, :owner

    def initialize(name, payload, owner: nil)
      @name = name.to_s
      @raw = payload.is_a?(Hash) ? payload : {}
      @owner = owner
    end

    # Whether the server sent resource linkage. False for every to-many, and
    # for a to-one that is either unset or not a belongs-to — this API cannot
    # tell those apart, so neither can this method.
    def loaded? = raw.key?("data")

    def many? = raw["data"].is_a?(Array)

    # The related record's identifier, for a to-one. Nil when the server sent
    # no linkage.
    def identifier
      JSONAPI::Identifier.from(raw["data"])
    end

    # Identifiers for a to-many. Always empty against today's API, which sends
    # no linkage for a to-many at all; kept because it costs nothing and starts
    # working the moment the server emits it.
    def identifiers
      return [] unless many?

      raw["data"].filter_map { |item| JSONAPI::Identifier.from(item) }
    end

    # The related record's id, for a to-one. The common reason to touch a
    # relationship at all: writing a foreign key into your own schema.
    def id = identifier&.id

    # The type the server reported for the related record. Not necessarily the
    # route it lives at (docs/release-blockers.md, RB-3).
    def type = identifier&.type

    # The URL the API gave for this relationship. Note that following it
    # returns the **full related resource**, not the resource linkage JSON:API
    # specifies for a relationship link — see FU-12.
    def link = raw.dig("links", "self")

    def meta = raw["meta"].is_a?(Hash) ? raw["meta"] : {}

    # The related record, if it travelled in the same document. Nil otherwise —
    # this does not go and get it.
    #
    # To-one only. A to-many yields nil, because `#identifier` is nil for array
    # linkage — there is no single record to return, and answering with
    # whichever came first would be worse than answering with nothing.
    #
    # It cannot be resolved from `included` either: the server sends no linkage
    # for a to-many, so in a collection response there is no way to tell which
    # parent an included record belongs to, and guessing by type would give
    # every customer every address. `#fetch` is the honest answer there.
    def resource
      payload = owner&.document&.find_included(identifier)
      return nil unless payload

      Resource.for(related_contract).new(payload, document: owner.document, client: owner.client)
    end

    # Gets the related record. The one method here that makes a request.
    #
    #   customer.addresses.fetch          # => Edge::ListObject
    #   demand.payer.fetch.email          # => "ada@example.com"
    #
    # Returns whatever the document holds: one resource, or a list. The shape
    # is read from the response rather than from the contract, so a
    # relationship the manifest has mis-recorded still comes back correctly.
    #
    # There is deliberately **no fall back to `Edge.default_client`**. A record
    # parsed without a client would otherwise reach for whatever global default
    # a process happens to hold — which, for anything serving more than one
    # merchant, is another merchant's credential and another merchant's data.
    # Failing closed is the only safe answer.
    def fetch(client: nil)
      raise Error, "#{name} carries no link to follow" if link.nil?

      client ||= owner&.client || no_client!
      document = JSONAPI::Document.from_response(client.get(link))
      klass = Resource.for(related_contract)

      return ListObject.new(document: document, client: client, resource_class: klass) if
        document.collection?

      klass.from(document, client: client)
    end

    def inspect
      "#<#{self.class.name} #{name} loaded=#{loaded?} id=#{id.inspect}>"
    end
    alias to_s inspect

    private

    def no_client!
      raise ConfigurationError,
            "#{name} cannot be fetched: this record was built without a client. Pass one as " \
            "`fetch(client:)`. It is not taken from Edge.default_client, because a record " \
            "belonging to one merchant must never be fetched with another's credentials."
    end

    # The manifest resource this relationship points at, resolved through the
    # view module name rather than the reported type, which can belong to
    # another resource entirely (RB-3).
    #
    # The camel-to-snake conversion covers every view name in the manifest
    # today; a name with an acronym run (`ACHDetails`) would not resolve, and
    # would fall back to the generated class for an unknown resource rather
    # than raising. A contract spec pins the current set.
    def related_contract
      spec = owner&.class&.contract_spec
      view = spec&.dig("relationships", name, "view")
      view&.gsub(/([a-z0-9])([A-Z])/, '\1_\2')&.downcase
    end
  end
end
