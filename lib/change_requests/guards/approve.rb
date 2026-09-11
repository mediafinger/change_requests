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

      # The quorums of the current stage this actor qualifies for - the same predicate
      # Request.awaiting_approval_from runs in SQL (§5.3).
      def eligible_quorums
        @eligible_quorums ||= qualifying(stage&.quorums&.pending)
      end

      # The subset an approval actually links to. Equal in M1; M9a makes it a strict subset under
      # all_quorums, where an approval links to exactly one quorum - the lowest-position one the
      # actor qualifies for - so one person cannot close two quorums that must both be met (§5.3).
      def countable_quorums
        eligible_quorums
      end

      private

      # §6.9: a stage-three director sitting on a stage-one request is told to wait, not refused.
      def eligible_on_another_stage?
        request.stages.where.not(id: stage&.id).any? { |other| qualifying(other.quorums).any? }
      end

      def qualifying(quorums)
        return [] if quorums.nil?

        quorums.select { |quorum| authorization.allows?(actor: actor, quorum: quorum) }
      end

      # One decision per stage per person. When the host declares a shared identity it is used in
      # place of (type, id), so one human cannot decide twice through two actor classes (§9.4).
      def already_decided?
        return false if stage.nil?

        decided_by_reference? || decided_by_identity?
      end

      def decided_by_reference?
        stage.approvals.exists?(approver_type: actor_ref[:type], approver_id: actor_ref[:id])
      end

      def decided_by_identity?
        identity = identity_of(actor)

        identity.present? && stage.approvals.exists?(approver_identity: identity)
      end
    end
  end
end
