# frozen_string_literal: true

module ChangeRequests
  module Guards
    # May this actor execute this request (§7.2, §8)?
    #
    # The §8.1 override branch is M3a-5. `Execution::Runner` drives the claim behind
    # `Commands::Execute`.
    #
    # Separation of duties is the one rule here with no counterpart in the other guards. `Approve`
    # refuses the requester by identity and consults nothing (I5); `Execute` refuses them *unless*
    # `config.requester_may_execute`, which defaults to false. Both use `same_person?`, so "is this
    # the same human" is answered identically - including through `config.actor_identity` (§9.4).
    class Execute < Base
      EXECUTABLE_STATUSES = %w(approved failed).freeze

      refuses_with NotExecutable

      def refusal
        return override_refusal if override?

        # `successful` is final, and "already done" is a better answer than "not approved".
        return :already_finalized if request.final?
        # Ahead of :not_approved, which would be untrue of a request that is approved and mid-flight.
        # T1's conditional UPDATE is the invariant beneath this, raising ExecutionInProgress (§8).
        return :executing if request.executing?
        return :not_approved unless EXECUTABLE_STATUSES.include?(request.status)
        return :attempts_exhausted if request.failed? && !request.retryable?
        return :not_permitted unless actor_type.may_execute
        return :requester if requester? && !config.requester_may_execute
        return :not_permitted if approver? && !config.approver_may_execute

        nil
      end

      # §8.1, and deliberately not a variation on the branch above. An override is not a lenient
      # execute: it asks whether this actor may suspend the gem's central promise on this action.
      #
      # Narrowed to `pending` on purpose. An approved or failed request executes by the ordinary
      # path, so recording an override for it would put a badge, an event and an `overridden_at` on
      # a request that needed none - and T1's conditional UPDATE takes `WHERE status = 'pending'`
      # for an override, which would otherwise refuse it far less clearly.
      def override_refusal
        return :already_finalized if request.final?
        return :executing if request.executing?
        return :override_not_permitted unless operation.overridable?
        return :not_pending unless request.pending?
        return :not_permitted unless actor_type.may_execute
        return :requester if requester? && !config.requester_may_override
        return :override_not_permitted unless satisfies_override_permissions?

        nil
      end

      def override?
        options[:override] ? true : false
      end

      private

      # An override declaring no permissions is open to anyone whose type may_execute, which the
      # branch above has already established (§8.1).
      def satisfies_override_permissions?
        policy = operation.override_policy

        return true if policy.unrestricted?

        Authorization::Permissions.held_by(actor, actor_type).intersect?(policy.permissions)
      end

      def actor_type
        config.actor_types.fetch(actor_ref[:type])
      end

      def requester?
        same_person?(request.requester, actor)
      end

      # Who actually decided, not who was merely eligible to: `approver_may_execute` is about
      # having spent a decision on this request, and it defaults to true.
      def approver?
        request.approvals.exists?(approver_type: actor_ref[:type], approver_id: actor_ref[:id])
      end
    end
  end
end
