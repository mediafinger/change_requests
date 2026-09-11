# frozen_string_literal: true

module ChangeRequests
  module Guards
    # May this actor call the whole thing off (§7.2)?
    #
    # The requester, or any eligible approver - eligible for a quorum on *any* stage, not just the
    # current one, per §7.2's preamble. Cancelling is a judgement about the request as a whole, not
    # about the step it happens to be sitting on.
    #
    # The reason is mandatory and `Commands::Cancel` enforces it, for the reason Reject does (Q25).
    class Cancel < Base
      refuses_with NotCancelable

      def refusal
        return :already_finalized if request.final?
        # The target is mid-flight. A status change cannot recall it, and setting a terminal status
        # would leave the execution unable to record its own outcome (Q28, §8).
        return :executing if request.executing?
        return :not_permitted unless requester? || eligible_approver?

        nil
      end

      private

      def requester?
        same_person?(request.requester, actor)
      end
    end
  end
end
