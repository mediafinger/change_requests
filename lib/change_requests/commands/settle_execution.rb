# frozen_string_literal: true

module ChangeRequests
  module Commands
    # §8's **T3**: what the target did. A separate transaction from T1 and from the invocation, so a
    # target that raises leaves no business change and still leaves a durable record of the failure.
    #
    # Internal, like ClaimExecution. `error:` nil is the success branch.
    class SettleExecution < Base
      # Enough to locate the failure, bounded so a deep stack cannot write a megabyte per attempt
      # into a host's database. The column is text; nothing else truncates it.
      BACKTRACE_FRAMES = 20

      def self.call(request:, actor:, attempt:, error: nil)
        new(request: request, actor: actor, attempt: attempt, error: error).call
      end

      def perform
        error.nil? ? record_success : record_failure

        request
      end

      private

      def attempt
        options.fetch(:attempt)
      end

      def error
        options[:error]
      end

      def record_success
        request.update!(status: "successful", executed_at: Time.current, executer: actor)
        attempt.update!(outcome: "succeeded", finished_at: Time.current)
        emit(:executed, metadata: { attempt: attempt.number })
      end

      # `failed` is not final: the request keeps its approval, and `retryable?` against max_attempts
      # is the only thing bounding another go (§8).
      def record_failure
        request.update!(status: "failed")
        attempt.update!(outcome: "failed", finished_at: Time.current, error_class: error.class.name,
                        error_message: error.message, backtrace: bounded_backtrace)
        emit(:execution_failed, body: error.message,
             metadata: { attempt: attempt.number, error_class: error.class.name })
      end

      def bounded_backtrace
        Array(error.backtrace).first(BACKTRACE_FRAMES).join("\n").presence
      end
    end
  end
end
