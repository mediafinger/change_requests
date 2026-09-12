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
    #
    # Once the operation is undeclared, **anyone** may cancel (§5.11, Q9). A request that can never
    # run is not worth adjudicating who may tidy it away, and leaving it clearable only by a rake
    # task means a stranded row sits in the table until an operator notices.
    class Cancel < Base
      refuses_with NotCancelable
      exempt_from_undeclared_operation!

      def refusal
        return :already_finalized if request.final?
        # The target is mid-flight. A status change cannot recall it, and setting a terminal status
        # would leave the execution unable to record its own outcome (Q28, §8). Ahead of the
        # undeclared branch: being undeclared does not make a running request recallable.
        return :executing if request.executing?
        # §5.11: the requester-or-approver rule is dropped along with the refusal, not before it.
        return nil if operation.nil?
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
