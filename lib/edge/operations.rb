# frozen_string_literal: true

module Edge
  # The HTTP operations a resource class exposes.
  #
  # Each is a separate module, and `contract` extends only the ones the
  # manifest says the endpoint has. That is the point: `PaymentMethod.create`
  # raises NoMethodError, because `/v2/payment_methods` is mounted
  # `only: [:index, :show]` (`core_web/router.ex:270-274`) and there is no
  # create route anywhere in the API. A method that existed and returned a 404
  # would be worse — it would look like a server problem rather than a
  # capability the API does not have.
  module Operations
    # Always extended. Everything the operations share.
    module Support
      # `v2/customers`. The API version belongs to the resource, not to the
      # client: `/v1` metering and `/v2` commerce are served side by side.
      def collection_path
        version = contract_spec&.fetch("api_version", nil)
        raise Error, "#{name} has no contract to build a path from" unless version

        "#{version}/#{contract_name}"
      end

      # Path segments are escaped with the URI parser's rules, not with
      # `encode_www_form_component`. The latter is for form bodies and encodes
      # a space as `+`, which a path does not decode: the server would see the
      # id `"a+b"` in the URL and `"a b"` in the body, and `id_required_plug`
      # would reject the mismatch with a 400 nobody could explain.
      UNRESERVED = /[^A-Za-z0-9\-._~]/

      # `.` and `..` are unreserved, so escaping leaves them intact and URI
      # resolution then removes them: `retrieve(".")` would address the
      # collection and fetch every record under a method that promises one.
      DOT_SEGMENTS = %w[. ..].freeze

      def member_path(id)
        "#{collection_path}/#{URI::DEFAULT_PARSER.escape(checked_id(id), UNRESERVED)}"
      end

      private

      def checked_id(id)
        id = id.to_s
        # `\p{Space}` rather than `strip`, which leaves a non-breaking space
        # standing. A blank id would otherwise be sent as `/v2/customers/%20`.
        raise ArgumentError, "an id is required, got #{id.inspect}" if id.match?(/\A\p{Space}*\z/)

        return id unless DOT_SEGMENTS.include?(id)

        raise ArgumentError,
              "#{id.inspect} is not an id. It would resolve away and address the collection, " \
              "returning every record to a method that promises one."
      end

      def client_for(client) = client || Edge.default_client

      # `resource:` and `strict:` come last so a caller's keyword cannot
      # displace them and quietly turn the name checking off, or point it at
      # another resource.
      def query_for(client, **query)
        Query.encode(**query, resource: contract_name, strict: client.config.strict)
      end

      def single(response, client)
        from(JSONAPI::Document.from_response(response), client: client)
      end

      def collection(response, client)
        ListObject.new(document: JSONAPI::Document.from_response(response),
                       client: client, resource_class: self)
      end
    end

    # Building the JSON:API request document, and refusing the ones the
    # server would answer with a 500 or silently ignore.
    module Body
      private

      # A JSON:API request document. `type` is the JSON:API type rather than
      # the route name — they differ (docs/release-blockers.md, RB-3) and the
      # server matches on the type.
      def body_for(attributes, relationships, id: nil)
        data = { "type" => json_api_type, "attributes" => stringify(attributes) }
        data["id"] = id.to_s if id
        # Inside `data`, which is where the server reads them from
        # (`phoenix_jsonapi/conn.ex:136`) and where JSON:API puts them.
        data["relationships"] = linkage(relationships) if relationships

        JSON.generate("data" => data)
      end

      def write_attributes(attributes, rest, client)
        checked_attributes(stringify(attributes).merge(stringify(rest)), client)
      end

      def stringify(attributes)
        raise ArgumentError, "attributes must be a Hash" unless attributes.is_a?(Hash)

        attributes.to_h { |key, value| [key.to_s, value] }
      end

      # An attribute the view does not declare is dropped without comment
      # (`phoenix_jsonapi/view.ex:107`), so a misspelled name returns 200 and
      # leaves the record unchanged.
      #
      # Names are only checked in strict mode, for the same reason Query's are:
      # the manifest is generated, and one that had fallen behind the server
      # would refuse a field that really is writable. What is checked always is
      # the 30 attributes the manifest records as `writable: false`, which is
      # positive knowledge rather than an absence of it.
      def checked_attributes(attributes, client)
        known = contract_spec&.fetch("attributes", nil) || {}
        attributes.each_key { |name| check_attribute(name, known, client) }
        attributes
      end

      def check_attribute(name, known, client)
        spec = known[name]
        return reject_unknown_attribute!(name, known) if spec.nil? && client.config.strict
        return if spec.nil? || spec["writable"] != false

        reject_readonly!(name)
      end

      def reject_readonly!(name)
        raise ArgumentError,
              "#{contract_name}.#{name} is set by the API, not by the caller. It would be " \
              "dropped from this request without comment."
      end

      def reject_unknown_attribute!(name, known)
        raise ArgumentError,
              "#{contract_name} has no attribute called #{name.inspect}. " \
              "#{suggestion(name, known.keys)}The API drops an attribute it does not recognise, " \
              "so this request would succeed and change nothing."
      end

      def suggestion(name, dictionary)
        return "" unless defined?(DidYouMean::SpellChecker)

        near = DidYouMean::SpellChecker.new(dictionary: dictionary).correct(name)
        near.empty? ? "" : "Did you mean #{near.first(3).map(&:inspect).join(", ")}? "
      end

      # Accepts what a caller is likely to have: a resource, an identifier, an
      # id, an array of any of those for a to-many, or a relationship object
      # already in JSON:API form.
      #
      # The name is checked first, for every value type. Checking it only on
      # the bare-id branch would have let a Resource or a pre-built hash past
      # the one guard that exists.
      def linkage(relationships)
        stringify(relationships).to_h do |name, value|
          spec = relationship_spec!(name)
          next [name, value] if prebuilt?(value)

          [name, { "data" => link_to(spec, name, value) }]
        end
      end

      # Both spellings. `{ data: {...} }` is the idiomatic Ruby literal, and
      # missing it sent the whole hash through `to_s` as an id — a request the
      # server accepts and then 404s on, which is harder to diagnose than a
      # rejection.
      def prebuilt?(value)
        value.is_a?(Hash) && (value.key?("data") || value.key?(:data))
      end

      def link_to(spec, name, value)
        return to_many(spec, name, value) if value.is_a?(Array)

        reject_unsettable!(name) if value.nil?
        identify(spec, name, value)
      end

      def to_many(spec, name, values)
        unless spec["cardinality"] == "many"
          raise ArgumentError,
                "#{contract_name}.#{name} holds one record, not a list. Pass the record or its " \
                "id — an array is sent as to-many linkage, which the API would reject here."
        end

        values.map { |value| identify(spec, name, value) }
      end

      def identify(spec, name, value)
        case value
        when Resource, JSONAPI::Identifier then identifier_for!(name, value)
        else { "type" => related_type(spec), "id" => value.to_s }
        end
      end

      # A Resource whose payload carried no `type` has no identifier, and
      # emitting `{"data": null}` for it would read as "unset this" — see
      # `reject_unsettable!` for why that is worse than an error.
      def identifier_for!(name, value)
        identifier = value.is_a?(Resource) ? value.identifier : value
        return identifier.to_h if identifier

        raise ArgumentError,
              "the record given for #{contract_name}.#{name} has no type and id, so it cannot " \
              "be linked to. Pass its id instead."
      end

      # `{"data": null}` reaches `fetch_relationship/3`
      # (`phoenix_jsonapi/conn.ex:256`), whose own comment reads
      # "TODO: Handle %{"data" => null}". It matches no clause, so the request
      # is a 500 rather than an unset. See docs/release-blockers.md, FU-13.
      def reject_unsettable!(name)
        raise ArgumentError,
              "#{contract_name}.#{name} cannot be unset: the API has no handling for null " \
              "linkage and answers with a 500. See docs/release-blockers.md, FU-13."
      end

      # The relationship must exist and be writable. The server rejects a name
      # it does not recognise (`conn.ex:169-189`); for one it recognises but
      # cannot write, the controller has no clause and the request is a 500.
      def relationship_spec!(name)
        spec = contract_spec&.dig("relationships", name)
        raise ArgumentError, unknown_relationship(name) unless spec
        return spec unless spec["writable"] == false

        raise ArgumentError,
              "#{contract_name}.#{name} is set by the API, not by the caller. Sending it is a " \
              "500, not a validation error."
      end

      def unknown_relationship(name)
        known = (contract_spec&.fetch("relationships", nil) || {}).keys
        "#{contract_name} has no relationship called #{name.inspect}. " \
          "#{suggestion(name, known)}The API rejects a relationship it does not recognise."
      end

      # The related resource's JSON:API type, which an id alone does not carry.
      # Resolved through the view module name rather than the reported type,
      # which can belong to another resource entirely (RB-3).
      def related_type(spec)
        Resource.for(spec["view"].gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase).json_api_type
      end
    end

    # `GET /v2/<resource>/<id>`.
    module Retrieve
      # One record by id.
      #
      #   Edge::Customer.retrieve("cus_1", include: %i[addresses])
      def retrieve(id, client: nil, **query)
        client = client_for(client)
        single(client.get(member_path(id), params: query_for(client, **query)), client)
      end
    end

    # `GET /v2/<resource>`.
    module List
      # A page of records. Today that is all of them — production does not
      # paginate (docs/pagination.md), so filter.
      #
      #   Edge::Customer.list(filter: { email: "ada@example.com" })
      def list(client: nil, **query)
        client = client_for(client)
        collection(client.get(collection_path, params: query_for(client, **query)), client)
      end
    end

    # `POST /v2/<resource>`.
    module Create
      # Creates a record.
      #
      #   Edge::Customer.create(email: "ada@example.com", name: "Ada")
      #   Edge::ConsumerAddress.create({ city: "London" }, relationships: { customer: customer })
      #
      # A relationship value may be a resource, an identifier, an id, an array
      # of those for a to-many, or a ready-made linkage hash. It may not be
      # nil: the API has no handling for null linkage and answers with a 500
      # (docs/release-blockers.md, FU-13).
      #
      # Attributes may be passed as a hash or as keywords. `client:` and
      # `relationships:` are reserved, so an attribute with either name — no
      # resource has one — must go in the hash.
      #
      # Not retriable. A repeat would create a second record: only
      # payment_demands and refund_demands document a replay contract, and they
      # carry an idempotency key for it.
      def create(attributes = {}, client: nil, relationships: nil, **rest)
        client = client_for(client)
        body = body_for(write_attributes(attributes, rest, client), relationships)
        single(client.post(collection_path, body: body), client)
      end
    end

    # `PATCH /v2/<resource>/<id>`.
    module Update
      # Updates a record. Attributes not named are left alone.
      #
      #   Edge::Customer.update("cus_1", email: "ada@example.com")
      def update(id, attributes = {}, client: nil, relationships: nil, **rest)
        client = client_for(client)
        body = body_for(write_attributes(attributes, rest, client), relationships, id: id)
        single(client.patch(member_path(id), body: body), client)
      end
    end

    # Keyed by the operation names the manifest uses. A name absent from here
    # is one this client does not know how to build, and `contract` raises on
    # it rather than quietly declaring a resource with a missing method.
    MODULES = {
      "retrieve" => Retrieve,
      "list" => List,
      "create" => Create,
      "update" => Update
    }.freeze
  end
end
