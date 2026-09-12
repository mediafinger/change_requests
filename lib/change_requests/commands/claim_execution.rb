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

      def self.call(request:, actor:)
        new(request: request, actor: actor).call
      end

      # The attempt, which T3 finishes.
      def perform
        authorize!
        claim!
        attempt = start_attempt
        emit(:execution_started, metadata: { attempt: attempt.number })

        attempt
      end

      private

      def authorize!
        Guards::Execute.new(request: request, actor: actor).check!
      end

      # §8's conditional UPDATE. The guard ran under this transaction's own FOR UPDATE, so in the
      # ordinary race the loser is already refused `:executing` and never arrives here. This is the
      # invariant beneath that: zero rows means somebody else holds the claim, whatever route got
      # here - a background re-entry, or a caller reaching the runner without the guard.
      def claim!
        claimed = Request.where(id: request.id, status: CLAIMABLE)
                         .update_all(status: "executing", updated_at: Time.current)

        refuse_claimed if claimed.zero?

        request.reload
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
