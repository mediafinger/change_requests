# frozen_string_literal: true

module ChangeRequests
  module Concerns
    # Every reference to a host record is a `(type, id, label)` triple, never a foreign key (§5.7):
    #
    #   actor_reference :requester
    #   actor_reference :executer, optional: true
    #   actor_reference :tenant, optional: true, registry: :tenant_types
    #   actor_reference :actor, allow_system: true
    #
    # Declares the validations, casts `*_id` to a String on write, and generates a reader and writer
    # over the whole triple, so a command assigns an actor object and the label is snapshotted:
    #
    #   request.requester = current_admin   # writes type, id and the label as it is now
    #   request.requester                   # => { type: "Admin", id: "42", label: "Grace (admin)" }
    #
    # M4 replaces that Hash with ActorRef, which resolves the live record and falls back to the
    # snapshot.
    module ActorColumns
      extend ActiveSupport::Concern

      class_methods do
        # `label: false` for a reference that names who *may* act rather than who did - the
        # eligibility rows carry no snapshot, because nothing has happened yet to snapshot.
        #
        # `identity: true` also snapshots `config.actor_identity`, which is what lets the gem tell
        # that Admin#7 and User#99 are one human. Null unless the host configured it (§9.4).
        def actor_reference(prefix, optional: false, allow_system: false, registry: :actor_types,
                            label: true, identity: false)
          declare_type_validation(prefix, optional: optional, allow_system: allow_system,
                                          registry: registry)

          unless optional
            validates :"#{prefix}_id", presence: true
            validates :"#{prefix}_label", presence: true if label
          end

          define_actor_accessors(prefix, registry: registry, label: label, identity: identity)
        end

        # QuorumPermission carries a type and nothing else: NULL there means "any registered class".
        def actor_type_reference(prefix, optional: true, registry: :actor_types)
          declare_type_validation(prefix, optional: optional, allow_system: false, registry: registry)
        end

        def permitted_actor_types(registry: :actor_types, allow_system: false)
          ChangeRequests.config.public_send(registry).keys + (allow_system ? [SYSTEM_ACTOR[:type]] : [])
        end

        private

        def declare_type_validation(prefix, optional:, allow_system:, registry:)
          validates :"#{prefix}_type", presence: true unless optional

          validates :"#{prefix}_type",
                    inclusion: {
                      in: ->(record) { record.class.permitted_actor_types(registry:, allow_system:) },
                    },
                    allow_nil: true
        end

        def define_actor_accessors(prefix, registry:, label:, identity:)
          generated = Module.new do
            # No `*_id=` override: the column is a string, so ActiveRecord already casts on
            # assignment. A User with a uuid key and an Admin with a bigint key share it (§5.7).
            define_method(prefix) do
              type = public_send(:"#{prefix}_type")

              return nil if type.blank?

              reference = { type: type, id: public_send(:"#{prefix}_id") }
              reference[:label] = public_send(:"#{prefix}_label") if label
              reference[:identity] = public_send(:"#{prefix}_identity") if identity

              reference
            end

            define_method(:"#{prefix}=") do |actor|
              attributes = if actor.nil?
                             { type: nil, id: nil, label: nil }
                           else
                             ChangeRequests.actor_attributes(actor, registry: registry)
                           end

              public_send(:"#{prefix}_type=", attributes[:type])
              public_send(:"#{prefix}_id=", attributes[:id])
              public_send(:"#{prefix}_label=", attributes[:label]) if label
              public_send(:"#{prefix}_identity=", ChangeRequests.config.actor_identity&.call(actor)) \
                if identity && actor
            end
          end

          include generated
        end
      end
    end
  end
end
