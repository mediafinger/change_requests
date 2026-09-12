# frozen_string_literal: true

module ChangeRequests
  # The scheduled sweeps (§8, §5.11). Each one is a query plus the command that owns its
  # transition, never a write of its own: the commands hold the locks and emit the events, and
  # these decide which rows to hand them (ADR 0016).
  #
  # Every event they cause carries the `System` sentinel, because `Commands::Base#emit` stamps it
  # when `actor` is nil - closing these rows out is the gem's own act, not anyone's decision.
  #
  # Each returns the number of rows it moved, which is what M3b-3's rake tasks report. Rows are
  # read into an array first: a sweep whose scope stops matching as it works should still visit
  # everything it set out to.
  #
  # `close_due_stages!` is **M9b** - a cooldown window has to exist before a stage can be due.
  module Maintenance
    module_function

    # `pending` / `approved` past `expires_at` become `expired`. The query is the same
    # `Request.expired_candidates` that `Guards::Expire` agrees with status for status (§8).
    def expire_stale!(now: Time.current)
      sweep(Request.expired_candidates(now)) { |request| Commands::Expire.call(request: request) }
    end

    # `executing` rows whose attempt nobody ever settled. T1 committed the claim and then the
    # process died; `executing` is the one status no other command will move, so without this the
    # row sits there forever (§8).
    def reap_stuck_executions!(older_than: Guards::Reap::DEFAULT_STUCK_AFTER)
      sweep(Request.stuck_executions(older_than)) do |request|
        Commands::Reap.call(request: request, older_than: older_than)
      end
    end

    # Non-final requests whose `operation_key` is no longer declared (§5.11). Deliberately not
    # automatic: a missing declaration is as likely to be a deploy accident as a deliberate
    # removal, and `canceled` is final - so this runs when an operator asks for it.
    def cancel_undeclared!
      sweep(Request.undeclared) { |request| Commands::CancelUndeclared.call(request: request) }
    end

    def sweep(scope, &)
      rows = scope.to_a
      rows.each(&)

      rows.size
    end
  end
end
