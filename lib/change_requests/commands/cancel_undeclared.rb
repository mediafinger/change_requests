# frozen_string_literal: true

module ChangeRequests
  module Commands
    # The sweeper closing out a request whose declaration vanished (§5.11).
    #
    #   Commands::CancelUndeclared.call(request:)
    #
    # `Cancel` with two things changed: the event kind, and the metadata. **Who cancelled decides
    # which event is emitted** (Q11) - a person cancelling a stranded request emits `canceled` with
    # their own reason, because they cancelled it; this emits `operation_undeclared`, because
    # "nobody decided this, its declaration vanished" is a different fact and a timeline should not
    # have to infer it from the actor column.
    #
    # It supplies its own reason, so `Cancel`'s mandatory-reason rule holds unchanged rather than
    # growing an exception. The text is translatable, not a hardcoded English sentence (§5.11).
    class CancelUndeclared < Cancel
      REASON_KEY = "change_requests.events.operation_undeclared"

      def self.call(request:)
        new(request: request, actor: nil, reason: reason).call
      end

      def self.reason
        Translation.translate(REASON_KEY,
                              default: "This operation is no longer declared, so the request " \
                                       "could never run.")
      end

      private

      def event_kind
        :operation_undeclared
      end

      # Alongside Cancel's `status`: what it was cancelled out of is still worth recording. The
      # version is the request's creation-time one - `Base#emit` falls back to it for the column
      # too, there being no live declaration to read - and it is the version whose disappearance
      # this event reports (§5.5, §5.11).
      def metadata
        super.merge(operation_key: request.operation_key,
                    operation_version: request.operation_version)
      end
    end
  end
end
