# frozen_string_literal: true

module ChangeRequests
  module Commands
    # Rejection is a stop, not a count (§7.1).
    #
    #   Commands::Reject.call(request:, actor: current_user, reason: "Wrong member")
    #
    # One rejection from any eligible approver, or from the requester, rejects the whole request.
    # Rejection thresholds are deliberately not modelled.
    #
    # `config.only_record_rejections = true` records the decision and the event without
    # short-circuiting: the workflow continues, and the rejector has spent their decision on that
    # stage - the unique index is what guarantees they cannot later approve it.
    class Reject < Base
      on_conflict NotRejectable, reason: :already_decided

      def self.call(request:, actor:, reason:)
        new(request: request, actor: actor, reason: reason).call
      end

      def perform
        Guards::Reject.new(request: request, actor: actor).check!
        refuse_without_reason

        record_decision
        emit(:rejected, body: reason, metadata: metadata)

        if config.only_record_rejections
          # The workflow continues, so the stage may still be satisfied by everyone else (§7.1).
          EvaluateWorkflow.call(request: request)
        else
          # No evaluation after `stop`: the request is already `rejected` and final, and re-entering
          # evaluation on it is at best a wasted query.
          stop
        end

        request
      end

      private

      def reason
        options[:reason]
      end

      # Authorization first: someone who may not reject at all should not be told they merely
      # forgot a sentence.
      def refuse_without_reason
        return if reason.present?

        fail NotRejectable.new(request: request, reason: :reason_required)
      end

      # Written in both branches, so change_request_approvals stays the complete record of who
      # decided what on each stage and the unique index behaves identically either way (Q26).
      def record_decision
        stage.approvals.create!(
          change_request: request,
          approver: actor,
          decision: "rejected",
          comment: reason,
          decided_at: Time.current
        )
      end

      # Whether the workflow continued is the fact an audit asks about first, and it depends on a
      # config flag that may since have been changed.
      def metadata
        { stage: stage.name, recorded_only: config.only_record_rejections }
      end

      def stop
        stage.update!(status: "rejected")
        request.update!(status: "rejected")
      end

      def stage
        @stage ||= request.current_stage
      end
    end
  end
end
