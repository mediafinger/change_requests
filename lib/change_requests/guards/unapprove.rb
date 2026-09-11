# frozen_string_literal: true

module ChangeRequests
  module Guards
    # May this actor take their own decision back (§7.1, §7.2)?
    #
    # Only the actor who gave it, and only while the stage they gave it on is still open. Cooldown
    # is M9b, so "open" means `pending` here.
    class Unapprove < Base
      refuses_with NotUnapprovable

      def refusal
        # A finished request is the same refusal whichever command met it, and Q29 maps this one
        # reason to AlreadyFinalized for every guard. `:not_pending` then means what it says:
        # open, but not open for decisions (Q48).
        return :already_finalized if request.final?
        return :not_pending unless request.pending?
        return :not_the_approver if decision.nil?
        return :stage_not_open unless decision.stage.pending?

        nil
      end

      # The row this actor is retracting - an approval, or a rejection recorded without
      # short-circuiting (§7.1). The command needs it, so it is resolved once, here.
      #
      # Matched on (type, id) alone. config.actor_identity says who *counts* as one person when
      # tallying approvers (§9.4); retracting is about which row this actor wrote, and one actor
      # undoing another's row would make the trail say something untrue.
      def decision
        return @decision if defined?(@decision)

        @decision = mine.find_by(change_request_stage_id: stage&.id) || mine.first
      end

      private

      def mine
        request.approvals
               .where(approver_type: actor_ref[:type], approver_id: actor_ref[:id])
               .order(decided_at: :desc)
      end
    end
  end
end
