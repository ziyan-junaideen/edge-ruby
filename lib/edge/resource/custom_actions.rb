# frozen_string_literal: true

module Edge
  class Resource
    # The endpoints that are not CRUD: `PATCH /v2/payment_demands/{id}/confirm`
    # and its counterpart on payment subscriptions, which the manifest records
    # as `custom_actions`.
    #
    # Its own module rather than more of Definition, which had grown past the
    # point where the next reader could hold it in their head.
    module CustomActions
      # Verbs a Client can send.
      SENDABLE = %i[get post patch].freeze
      private_constant :SENDABLE

      # Declares one of the manifest's custom actions — today only
      # `PATCH /{id}/confirm` — as a class method taking an id and as an
      # instance method taking none.
      #
      #   PaymentDemand.confirm("pd_1")   # => Edge::PaymentDemand
      #   demand.confirm                  # same request, same client
      #
      # Opt-in rather than generated from `custom_actions` wholesale, unlike
      # the CRUD operations. A route existing is not the same as this client
      # knowing what it means: `confirm` retries a *failed* payment demand and
      # separately promotes a payment intent, which is two behaviours that
      # need documenting where the class is, not a method conjured from a path
      # string. Generating them would also quietly hand one to every
      # `Resource.for` class the manifest can build.
      #
      # The response is the record as the server returns it — a new object.
      # Nothing here mutates the receiver: `raw` belongs to a frozen document,
      # and a resource that changed under a caller who still held a reference
      # to the old state would be the worst of both.
      def custom_action(name)
        name = name.to_s
        verb = custom_action_verb!(name)
        reject_taken_action!(name)

        define_singleton_method(name) do |id, client: nil|
          client = client_for(client)
          # No attributes: `do_confirm/2` reads only `preloadable_includes`
          # from the payload and ignores everything else, so anything sent
          # here would be accepted and dropped without comment.
          body = body_for({}, nil, id: id)
          single(client.public_send(verb, action_path(id, name), body: body), client)
        end

        define_method(name) { self.class.public_send(name, id, client: client_for_action!(name)) }
      end

      private

      # The action must be one the manifest records for this resource, and its
      # verb one this client can send. A method for a route the API does not
      # have is a 404 dressed up as a capability — the same failure
      # `define_operations` exists to prevent — and a verb Client cannot send
      # is a NoMethodError deep inside the first call rather than here.
      def custom_action_verb!(name)
        unless contract_spec
          raise ArgumentError,
                "#{self} must declare `contract` before `custom_action #{name.inspect}`: the " \
                "manifest entry is what says the route exists."
        end

        checked_verb(name, find_action!(name))
      end

      def find_action!(name)
        actions = contract_spec["custom_actions"] || []
        # On the whole path, not on the name appearing somewhere inside one.
        found = actions.find { |action| action["path"] == "/{id}/#{name}" }
        return found if found

        raise ArgumentError,
              "#{contract_name} has no custom action at /{id}/#{name}. " \
              "contract/manifest.yml records #{actions.map { |a| a["path"] }.inspect}."
      end

      def checked_verb(name, action)
        verb = action["verb"].to_s.downcase.to_sym
        return verb if SENDABLE.include?(verb)

        raise ArgumentError,
              "#{contract_name}'s #{name} action is #{action["verb"].inspect}, which this " \
              "client cannot send. Edge::Client speaks #{SENDABLE.join(", ")}."
      end

      # An action that silently replaced `#id` or `#type` would break the
      # object a long way from this declaration.
      #
      # Both sides are checked, because `custom_action` defines both. Checking
      # only the instance side let an action named after a generated class
      # method — `update`, say — clobber it silently, leaving
      # `PaymentDemand.update` taking `(id, client:)` and writing nothing.
      def reject_taken_action!(name)
        taken = method_defined?(name) || private_method_defined?(name) ||
                singleton_class.method_defined?(name) ||
                singleton_class.private_method_defined?(name)
        return unless taken

        raise ArgumentError,
              "#{contract_name} cannot declare the action #{name.inspect}: that name is already " \
              "a method on #{self}."
      end
    end
  end
end
