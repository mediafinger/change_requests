# frozen_string_literal: true

module ChangeRequests
  # The minimum needed to write a concurrency spec (§15.3). The host-facing test kit is M8.
  module Testing
    module_function

    # Runs the block on `count` real threads, each with its own connection, released together.
    #
    #   results = Testing.in_parallel(2) { |i| Commands::Approve.call(request:, actor: actors[i]) }
    #
    # Returns one entry per thread, in order: the block's value, or the exception it raised.
    # Raising is an outcome here rather than a failure - "the loser of this race is told X" is the
    # whole claim - so nothing is re-raised and the caller decides what the pair should be.
    #
    # Threads start blocked on a barrier and are released at once, which is what makes them race
    # rather than run one after another. `connection_pool.with_connection` gives each its own
    # connection and returns it afterwards, so the pool is not drained by a spec that fails.
    def in_parallel(count)
      gate = Barrier.new(count)

      threads = Array.new(count) do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.wait
            begin
              yield(index)
            rescue StandardError => e
              e
            end
          end
        end
      end

      threads.map(&:value)
    end

    # Everyone waits until the last one arrives, then all proceed. Ruby ships no barrier and
    # concurrent-ruby is not a dependency of this gem.
    class Barrier
      def initialize(count)
        @count = count
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @arrived = 0
      end

      def wait
        @mutex.synchronize do
          @arrived += 1

          next @condition.broadcast if @arrived >= @count

          @condition.wait(@mutex) while @arrived < @count
        end
      end
    end
  end
end
