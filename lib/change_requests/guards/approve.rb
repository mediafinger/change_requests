# frozen_string_literal: true

module ChangeRequests
  module Guards
    # May this actor approve this request right now (§7, §7.2)?
    #
    # The branch order is the contract: it decides which reason a user sees, and "not your turn yet"
    # is a different answer from "you cannot approve this at all".
    class Approve < Base
      refuses_with NotApprovable

      def refusal
        # A finished request is the same refusal whichever command met it, and Q29 maps this one
        # reason to AlreadyFinalized for every guard. `:not_pending` then means what it says:
        # open, but not open for decisions (Q48).
        return :already_finalized if request.final?
        return :not_pending unless request.pending?
        # Never configurable. There is no config.requester_may_approve to read, in any form (I5).
        return :requester if same_person?(request.requester, actor)
        return :stage_not_current if eligible_quorums.empty? && eligible_on_another_stage?
        return :already_decided if already_decided?
        return :not_permitted if eligible_quorums.empty?

        nil
      end

      # The subset an approval actually links to (§5.3, §7.1).
      #
      # Under `any_quorum` the quorums are alternative routes to the same gate, so an approval
      # counts toward every one the actor qualifies for. Under `all_quorums` they are all required,
      # and an approval counts toward **exactly one** - otherwise a stage declared "one Admin AND
      # two Owners" closes on two people, which is what its own prose says it must not do.
      #
      # The lowest position wins, and position is declaration order: a host reads their own
      # declaration top to bottom and knows where an approval will land. `eligible_quorums` is
      # already scoped to pending ones, so a quorum that is full is never the candidate and the
      # next approval goes where there is still room.
      def countable_quorums
        return eligible_quorums unless stage&.all_quorums?

        Array(eligible_quorums.min_by(&:position))
      end
    end
  end
end
