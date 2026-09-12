# frozen_string_literal: true

module ChangeRequests
  module Commands
    # The clock writing off an execution nobody finished (§8).
    #
    #   Commands::Reap.call(request:)
    #
    # T1 claimed the request and committed; then the process died, the box was replaced, or the job
    # backend lost the work. Nothing will ever settle that attempt, so the row would sit `executing`
    # forever - and `executing` is the one status no other command will move (Q28).
    #
    # No actor: `emit` stamps `SYSTEM_ACTOR`, so "who did this" is answerable for every row (§5.5).
    # `Maintenance.reap_stuck_executions!` is the sweep around this transition.
    class Reap < Base
      def self.call(request:, older_than: Guards::Reap::DEFAULT_STUCK_AFTER)
        new(request: request, actor: nil, older_than: older_than).call
      end

      def perform
        guard = Guards::Reap.new(request: request, actor: actor, older_than: options[:older_than])
        guard.check!

        attempt = guard.stuck_attempt

        # Emitted before the status changes, as Expire does: the trail records what was reaped
        # rather than what it became, which is `failed` for every one of these rows.
        emit(:reaped, metadata: { attempt: attempt.number, stuck_for: guard.stuck_for })

        attempt.update!(outcome: "abandoned", finished_at: Time.current)
        request.update!(status: "failed")

        request
      end
    end
  end
end
