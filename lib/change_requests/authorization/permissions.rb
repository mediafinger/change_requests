# frozen_string_literal: true

module ChangeRequests
  module Authorization
    # The default policy: does this actor satisfy this quorum's eligibility rows (§5.3, §9.2)?
    #
    # Written once. M9c re-expresses the identical predicate as the SQL of
    # `Request.awaiting_approval_from`, so "the button is enabled" and "it appears in my inbox"
    # cannot drift apart.
    class Permissions
      # Through the actor type's own lambda, never through a method on the actor: User and Admin may
      # derive their permissions completely differently and still be compared against one
      # definition (§9.2). Also read by Guards::Execute's override branch, which has no quorum.
      def self.held_by(actor, type)
        return [] if type.nil? || type.permissions.nil?

        Array(type.permissions.call(actor)).map(&:to_s)
      end

      # `action` is ignored here - eligibility is the same question whichever command asks it. It
      # exists because Authorization::Callable hands it on to the host's own policy.
      def allows?(actor:, quorum:, action: :approve) # rubocop:disable Lint/UnusedMethodArgument
        type = registered_type(actor)

        return false unless type.may_approve

        named_approver?(actor, quorum) || satisfies_permission_rows?(actor, type, quorum)
      end

      private

      # Raises UnknownActorType for a class that is not registered: the registry is the allowlist,
      # and an unregistered class cannot enter the system through any path (§9.1).
      def registered_type(actor)
        name = actor.class.name
        type = ChangeRequests.config.actor_types[name]

        return type if type

        fail UnknownActorType,
             "#{name} is not a registered actor type. " \
             "Register it with `config.actor_type \"#{name}\"`."
      end

      def named_approver?(actor, quorum)
        quorum.eligible_actors.any? do |row|
          row.actor_type == actor.class.name && row.actor_id == actor.id.to_s
        end
      end

      def satisfies_permission_rows?(actor, type, quorum)
        rows = quorum.permissions.to_a

        # "all of nothing" is vacuously true, which would let a quorum that only names its approvers
        # admit everyone. A quorum with no rows grants eligibility to nobody by permission.
        return false if rows.empty?

        held    = permissions_of(actor, type)
        matched = rows.select { |row| row_matches?(row, actor, held) }

        quorum.all_match? ? matched.size == rows.size : matched.any?
      end

      # The 2x2 of §5.3. A row constraining neither axis matches nobody: "constrains nothing" is a
      # bug the model and the CHECK both refuse, never a wildcard.
      def row_matches?(row, actor, held)
        return false if row.permission.nil? && row.actor_type.nil?

        (row.permission.nil? || held.include?(row.permission)) &&
          (row.actor_type.nil? || row.actor_type == actor.class.name)
      end

      def permissions_of(actor, type)
        self.class.held_by(actor, type)
      end
    end
  end
end
