# frozen_string_literal: true

module ChangeRequests
  module Commands
    # Records one approver's decision and which quorums it counted toward (§7).
    #
    #   Commands::Approve.call(request:, actor: current_user, comment: "Checked with HR")
    class Approve < Base
      # §15.3: two concurrent approvals by the same actor race the unique index, and the loser must
      # hear the same refusal the guard would have given, not a 500.
      on_conflict NotApprovable, reason: :already_decided

      def self.call(request:, actor:, comment: nil)
        new(request: request, actor: actor, comment: comment).call
      end

      def perform
        # Built once and asked twice: the reason it refuses and the quorums it links must come from
        # one evaluation, not two (I7).
        guard = Guards::Approve.new(request: request, actor: actor)
        guard.check!

        approval = record_decision
        link(approval, guard.countable_quorums)
        emit(:approved, body: comment, metadata: metadata_for(approval))

        # Commands::EvaluateWorkflow is M1b-12. Until it lands nothing advances the stage.
        request
      end

      private

      def comment
        options[:comment]
      end

      def record_decision
        stage.approvals.create!(
          change_request: request,
          approver: actor,
          decision: "approved",
          comment: comment,
          decided_at: Time.current
        )
      end

      # Written at decision time and never re-derived, so a later role change cannot silently
      # un-approve a request (§5.3).
      def link(approval, quorums)
        quorums.each { |quorum| approval.approval_quorums.create!(quorum: quorum) }
      end

      # The quorum key is omitted for a stage of one nameless quorum, because "which quorum" is not
      # a meaningful question there (§5.9).
      def metadata_for(approval)
        metadata = { stage: stage.name }
        names = approval.quorums.map(&:name).compact

        metadata[:quorums] = names if names.any?

        metadata
      end

      def stage
        @stage ||= request.current_stage
      end
    end
  end
end
