# frozen_string_literal: true

module ChangeRequests
  module Commands
    # Calls the whole request off (§7.2).
    #
    #   Commands::Cancel.call(request:, actor: current_user, reason: "No longer needed")
    #
    # `canceled` is final. Unlike a rejection there is no stage-level counterpart and no cooldown:
    # cancelling is not a decision on a step, it is the end of the request.
    class Cancel < Base
      def self.call(request:, actor:, reason:)
        new(request: request, actor: actor, reason: reason).call
      end

      def perform
        Guards::Cancel.new(request: request, actor: actor).check!
        refuse_without_reason

        # Emitted before the status changes, so the trail records the request as it was cancelled
        # rather than as it ended up.
        emit(event_kind, body: reason, metadata: metadata)
        request.update!(status: "canceled")

        request
      end

      private

      # The two seams CancelUndeclared overrides, and the whole of the difference between them:
      # who cancelled decides which fact the timeline records (Q11, §5.11).
      def event_kind
        :canceled
      end

      def metadata
        { status: request.status }
      end

      def reason
        options[:reason]
      end

      # Authorization first, as in Reject: someone who may not cancel at all should not be told
      # they merely forgot a sentence.
      def refuse_without_reason
        return if reason.present?

        fail NotCancelable.new(request: request, reason: :reason_required)
      end
    end
  end
end
