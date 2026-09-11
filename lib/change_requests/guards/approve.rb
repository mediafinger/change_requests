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
        return :not_pending unless request.pending?
        # Never configurable. There is no config.requester_may_approve to read, in any form (I5).
        return :requester if same_person?(request.requester, actor)
        return :stage_not_current if eligible_quorums.empty? && eligible_on_another_stage?
        return :already_decided if already_decided?
        return :not_permitted if eligible_quorums.empty?

        nil
      end

      # The subset an approval actually links to. Equal in M1; M9a makes it a strict subset under
      # all_quorums, where an approval links to exactly one quorum - the lowest-position one the
      # actor qualifies for - so one person cannot close two quorums that must both be met (§5.3).
      def countable_quorums
        eligible_quorums
      end
    end
  end
end
