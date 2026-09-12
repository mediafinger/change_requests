# frozen_string_literal: true

module ChangeRequests
  module Guards
    # May this request's abandoned execution be written off (§8)?
    #
    # System only, for the reason `Expire` is: nobody reaps a request on purpose, the clock does,
    # so an actor being supplied at all is the refusal. Every refusal is `NotAuthorized` rather
    # than a TransitionError apart from the shared `:already_finalized` mapping - the only caller
    # is `Maintenance.reap_stuck_executions!`, whose query already filters on status and age, so
    # these branches are a floor beneath it and never a user-facing flash (Q32).
    # Exempt from the undeclared-operation refusal, joining Comment and Cancel (§5.11). Whether
    # the declaration still exists has no bearing on "this attempt died and nobody will settle it" -
    # and Cancel refuses an `executing` request (Q28), so without this a row claimed just as its
    # declaration vanished could be cleared by nothing at all.
    class Reap < Base
      # §8's documented default, in seconds rather than `1.hour`: the domain core loads against a
      # bare ActiveRecord, which does not bring active_support/core_ext/numeric/time with it. A
      # host passing `1.hour` still works - a Duration subtracts from a Time exactly the same.
      DEFAULT_STUCK_AFTER = 3600

      refuses_with NotAuthorized
      exempt_from_undeclared_operation!

      def refusal
        return :not_system unless actor.nil?
        return :already_finalized if request.final?
        return :not_executing unless request.executing?
        return :not_stuck if stuck_attempt.nil?

        nil
      end

      # The attempt the reaper writes off, exposed so the command writes the same row the guard
      # judged - one guard object, built once (I7).
      def stuck_attempt
        return @stuck_attempt if defined?(@stuck_attempt)

        @stuck_attempt = request.attempts.in_flight.where(started_at: ..cutoff).order(:number).last
      end

      def stuck_for(now = Time.current)
        return nil if stuck_attempt&.started_at.nil?

        (now - stuck_attempt.started_at).round
      end

      private

      def cutoff
        Time.current - older_than
      end

      def older_than
        options.fetch(:older_than, DEFAULT_STUCK_AFTER)
      end
    end
  end
end
