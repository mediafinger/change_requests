# frozen_string_literal: true

module ChangeRequests
  module Commands
    # The clock closing a request nobody acted on (§7.2, §8).
    #
    #   Commands::Expire.call(request:)
    #
    # No actor: `emit` stamps `SYSTEM_ACTOR` rather than a NULL, so "who did this" is answerable for
    # every row and no presenter branches on nil (§5.5, §19.15).
    #
    # This is the transition only. `Maintenance.expire_stale!`, which sweeps
    # `Request.expired_candidates` on a schedule, is M3b.
    class Expire < Base
      def perform
        Guards::Expire.new(request: request, actor: actor).check!

        # Emitted before the status changes, so the trail records what expired rather than what it
        # became - which is `expired` for every one of these rows.
        emit(:expired, metadata: { status: request.status, expires_at: request.expires_at })
        request.update!(status: "expired")

        request
      end
    end
  end
end
