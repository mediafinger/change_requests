# frozen_string_literal: true

module ChangeRequests
  class Workflow
    # One counting rule of the described workflow (§5.3). `name` is null when its stage holds
    # exactly one quorum - `w.stage` without a block (§5.9).
    #
    # `eligible_actors` holds the actor objects as the host declared them. Resolving them to
    # (type, id) here would call `actor_attributes` from an initializer, before the file that
    # registers the actor types has necessarily run; `Commands::Create` resolves them instead.
    Quorum = Data.define(:name, :position, :threshold, :permission_match, :permissions,
                         :eligible_actors) do
      alias_method :declared_permission_match, :permission_match

      # Resolved lazily, so a host that sets its default after declaring its operations gets it.
      def permission_match
        declared_permission_match || ChangeRequests.config.default_permission_match
      end
    end
  end
end
