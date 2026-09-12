# frozen_string_literal: true

module ChangeRequests
  module Commands
    # §8's **T1**: the claim. Guard, take the row, write the attempt, emit - and commit, so the
    # claim is visible to every other process *before* the target runs.
    #
    # An **internal** command, like EvaluateWorkflow: hosts call `Commands::Execute`, which reaches
    # it through `Execution::Runner`. It is a command rather than a Runner method because every
    # event in the gem is written by one, through one `emit` (ADR 0016).
    class ClaimExecution < Base
      CLAIMABLE = %w(approved failed).freeze

      # §8.1: an override claims a request that never reached `approved`.
      OVERRIDE_CLAIMABLE = %w(pending).freeze

      def self.call(request:, actor:, override: false, reason: nil)
        new(request: request, actor: actor, override: override, reason: reason).call
      end

      # The attempt, which T3 finishes.
      def perform
        authorize!
        refuse_without_reason
        claim!
        record_override if override?
        attempt = start_attempt
        emit(:execution_started, metadata: { attempt: attempt.number })

        attempt
      end

      private

      def authorize!
        Guards::Execute.new(request: request, actor: actor, override: override?).check!
      end

      def override?
        options[:override] ? true : false
      end

      def reason
        options[:reason]
      end

      # After the guard, following M1b-7's shape (Q25): someone who may not override at all should
      # not be told they merely forgot a sentence.
      def refuse_without_reason
        return unless override?
        return unless operation.override_policy.require_reason?
        return if reason.present?

        fail OverrideNotPermitted.new(request: request, reason: :reason_required)
      end

      # §8.1: at claim time, inside T1, carrying the shortfall exactly as it stood. A later
      # approval must not be able to make an override look retrospectively unnecessary.
      def record_override
        request.update!(overridden_at: Time.current)
        emit(:overridden, body: reason, metadata: shortfall)
      end

      # Scoped to what is still missing rather than to the whole workflow: what an auditor asks is
      # how far short this request was when someone went ahead anyway.
      def shortfall
        stages  = request.stages.reject { |stage| stage.satisfied? || stage.closed? }
        quorums = stages.flat_map { |stage| stage.quorums.reject(&:satisfied?) }

        {
          approvals_present: quorums.sum { |quorum| quorum.approval_quorums.count },
          approvals_required: quorums.sum(&:threshold),
          incomplete_stages: stages.map(&:name),
          # Omitted rather than null for a single-quorum stage, as every other event does (§5.9).
          incomplete_quorums: quorums.filter_map(&:name),
        }
      end

      # §8's conditional UPDATE. The guard ran under this transaction's own FOR UPDATE, so in the
      # ordinary race the loser is already refused `:executing` and never arrives here. This is the
      # invariant beneath that: zero rows means somebody else holds the claim, whatever route got
      # here - a background re-entry, or a caller reaching the runner without the guard.
      def claim!
        claimed = Request.where(id: request.id, status: claimable)
                         .update_all(status: "executing", updated_at: Time.current)

        refuse_claimed if claimed.zero?

        request.reload
      end

      def claimable
        override? ? OVERRIDE_CLAIMABLE : CLAIMABLE
      end

      # The unique index on (change_request_id, number) is the claim's second lock: two processes
      # cannot both create attempt 3, whatever they believe about the status column (§5.6).
      def start_attempt
        request.attempts.create!(number: Attempt.next_number_for(request),
                                 executer: actor, started_at: Time.current)
      rescue ActiveRecord::RecordNotUnique
        refuse_claimed
      end

      def refuse_claimed
        fail ExecutionInProgress,
             "Change request #{request.id} is already being executed. The claim is committed " \
             "before the target runs, so another process holds this attempt (§8)."
      end
    end
  end
end
