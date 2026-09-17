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
    #   request.requester                   # => ActorRef
    #
    # The reader returns an `ActorRef` (§9.1), which answers the stored triple with no query and
    # resolves the live record only when asked for a fresh label, the record itself or a path.
    module ActorColumns
      extend ActiveSupport::Concern

      class_methods do
        # `identity: true` also snapshots `config.actor_identity`, which is what lets the gem tell
        # that Admin#7 and User#99 are one human. Null unless the host configured it (§9.4).
        def actor_reference(prefix, optional: false, allow_system: false, registry: :actor_types,
                            identity: false)
          declare_type_validation(prefix, optional: optional, allow_system: allow_system,
                                          registry: registry)

          unless optional
            validates :"#{prefix}_id", presence: true
            validates :"#{prefix}_label", presence: true
          end

          define_actor_accessors(prefix, registry: registry, identity: identity)
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

        def define_actor_accessors(prefix, registry:, identity:)
          generated = Module.new do
            # No `*_id=` override: the column is a string, so ActiveRecord already casts on
            # assignment. A User with a uuid key and an Admin with a bigint key share it (§5.7).
            define_method(prefix) do
              type = public_send(:"#{prefix}_type")

              return nil if type.blank?

              columns = { label: public_send(:"#{prefix}_label") }
              columns[:identity] = public_send(:"#{prefix}_identity") if identity

              ActorRef.new(type: type, id: public_send(:"#{prefix}_id"), **columns)
            end

            define_method(:"#{prefix}=") do |actor|
              attributes = if actor.nil?
                             { type: nil, id: nil, label: nil }
                           else
                             ChangeRequests.actor_attributes(actor, registry: registry)
                           end

              public_send(:"#{prefix}_type=", attributes[:type])
              public_send(:"#{prefix}_id=", attributes[:id])
              public_send(:"#{prefix}_label=", attributes[:label])
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
