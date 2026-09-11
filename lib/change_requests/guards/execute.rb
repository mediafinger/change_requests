# frozen_string_literal: true

module ChangeRequests
  module Guards
    # May this actor execute this request (§7.2, §8)?
    #
    # **Guard only.** `Commands::Execute`, the claim-then-invoke machinery and the §8.1 override
    # branch are M3a (decision D2). The guard's inputs are all M1 state; the claim is not.
    #
    # Separation of duties is the one rule here with no counterpart in the other guards. `Approve`
    # refuses the requester by identity and consults nothing (I5); `Execute` refuses them *unless*
    # `config.requester_may_execute`, which defaults to false. Both use `same_person?`, so "is this
    # the same human" is answered identically - including through `config.actor_identity` (§9.4).
    class Execute < Base
      EXECUTABLE_STATUSES = %w(approved failed).freeze

      refuses_with NotExecutable

      def refusal
        # `successful` is final, and "already done" is a better answer than "not approved".
        return :already_finalized if request.final?
        return :not_approved unless EXECUTABLE_STATUSES.include?(request.status)
        return :attempts_exhausted if request.failed? && !request.retryable?
        return :not_permitted unless actor_type.may_execute
        return :requester if requester? && !config.requester_may_execute
        return :not_permitted if approver? && !config.approver_may_execute

        nil
      end

      private

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
