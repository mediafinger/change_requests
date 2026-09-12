# frozen_string_literal: true

module ChangeRequests
  module Execution
    # §8's three transactions, which are the whole double-execution fix:
    #
    #   T1  claim   with_lock, conditional UPDATE, attempt, execution_started, COMMIT
    #   T2  invoke  no lock - may take seconds, may call an external API
    #   T3  settle  with_lock, the outcome on the request and on the attempt, and its event
    #
    # The claim is committed before the side effect runs, which is what makes this stronger than
    # one lock around all three: nothing in T2 holds the row, so the request is visibly `executing`
    # to every other process and to the UI while the target works.
    #
    # `Commands::Execute` is the host-facing entry point (M3a-3); this is the machinery.
    class Runner
      def self.call(request:, actor:, override: false, reason: nil)
        new(request: request, actor: actor, override: override, reason: reason).call
      end

      # T2 and T3 alone: T1 committed in another process, which is what Execution::Job resumes.
      def self.finish(request:, attempt:)
        new(request: request).finish(attempt)
      end

      def initialize(request:, actor: nil, override: false, reason: nil)
        @request  = request
        @actor    = actor
        @override = override
        @reason   = reason
      end

      def call
        attempt = Commands::ClaimExecution.call(request: request, actor: actor,
                                                override: override, reason: reason)

        # T1 commits either way, so the request is visibly `executing` the moment this returns -
        # which is the whole reason background mode does not enqueue the claim as well (§8).
        return enqueue(attempt) if background?

        finish(attempt)
      end

      def finish(attempt)
        begin
          invoke
        rescue StandardError => e
          # Recorded before it is re-raised, and re-raised from inside this rescue so `#cause` is
          # the target's own error. The attempt row carries its class too, so a host that needs to
          # tell a misconfiguration from a flaky call reads `error_class` rather than unwrapping.
          settle(attempt, e)

          raise TargetFailed, "#{target_description} raised #{e.class}: #{e.message}"
        end

        settle(attempt, nil)
      end

      private

      attr_reader :request, :actor, :override, :reason

      def background?
        ChangeRequests.config.execution_mode == :background
      end

      # The ids, not the objects: §8's job takes what survives serialisation. Returns the claimed
      # request, so a caller sees what inline mode gives it - a row, already `executing`.
      def enqueue(attempt)
        ChangeRequests.background_job!
                      .set(queue: ChangeRequests.config.job_queue)
                      .perform_later(request.id, attempt.id)

        request.reload
      end

      def invoke
        Dispatcher.call(operation_key: request.operation_key, payload: request.payload,
                        change_request_id: request.id)
      end

      # From the declaration, never from the row's columns: those are the creation-time snapshot,
      # and naming them here would report a target that did not run (§6.12 point 1).
      def target_description
        operation = ChangeRequests.operations[request.operation_key]

        return request.operation_key if operation.nil?

        "#{operation.service}.#{operation.method_name}"
      end

      # No actor: the attempt carries the executer's triple from T1, which is what T3 records.
      # That is what lets the job settle a claim it did not make (§5.6).
      def settle(attempt, error)
        Commands::SettleExecution.call(request: request, attempt: attempt, error: error)
      end
    end
  end
end
