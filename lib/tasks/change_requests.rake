# frozen_string_literal: true

# Loaded by the engine's lib/tasks path, so a host gets these from its own `Rails.application
# .load_tasks` with nothing to require.
#
# The three sweepers below raise on error and say nothing else, so cron's own mail-on-failure is
# the alarm. See docs/05_execution_and_idempotency.md for which of them belong on a schedule.
namespace :change_requests do
  # A local rather than a method: `def` in a .rake file defines on the top level, where it would
  # collide with whatever the host calls its own helpers. The task blocks close over it.
  #
  # Rake exits non-zero when a task raises, so nothing below rescues: an error is an error, and a
  # sweep that moved nothing is not one.
  report = lambda do |verb, count|
    puts "ChangeRequests: #{verb} #{count} #{"request".pluralize(count)}."
  end

  desc "Verify every declared operation: its version, target and workflow (§6.12 point 6)"
  task verify: :environment do
    count = ChangeRequests.operations.keys.size

    begin
      ChangeRequests.operations.verify!
    rescue ChangeRequests::ConfigurationError => e
      warn e.message

      # Non-zero so CI fails on it. `exit` rather than `abort`, whose message would repeat e.
      exit 1
    end

    puts "ChangeRequests: #{count} #{"operation".pluralize(count)} verified."
  end

  desc "Expire pending and approved requests whose deadline has passed (§8)"
  task expire_stale: :environment do
    report.call("expired", ChangeRequests::Maintenance.expire_stale!)
  end

  desc "Write off executions nobody settled - OLDER_THAN seconds, default one hour (§8)"
  task reap_stuck_executions: :environment do
    older_than = ENV.fetch("OLDER_THAN", nil)&.to_i

    count = if older_than
              ChangeRequests::Maintenance.reap_stuck_executions!(older_than: older_than)
            else
              ChangeRequests::Maintenance.reap_stuck_executions!
            end

    report.call("reaped", count)
  end

  # Deliberately not on a schedule: a missing declaration is as likely to be a deploy accident as
  # a deliberate removal, and `canceled` is final (§5.11). Refusal and invisibility are immediate
  # and reversible; this is not.
  desc "Cancel open requests whose operation is no longer declared - run by hand (§5.11)"
  task cancel_undeclared: :environment do
    report.call("canceled", ChangeRequests::Maintenance.cancel_undeclared!)
  end
end
