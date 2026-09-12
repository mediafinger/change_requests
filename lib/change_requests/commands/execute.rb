# frozen_string_literal: true

module ChangeRequests
  module Commands
    # §6.6's sixth command, in the shape of the other five: the request, the acting actor, and a
    # typed error on refusal.
    #
    #   Commands::Execute.call(request:, actor: current_user)
    #
    # The work is §8's three transactions, so this is the one command that takes **no lock of its
    # own**: `Execution::Runner` opens one per transaction, and none of them spans the target
    # invocation. `Guards::Execute` runs inside T1, against the row it locked - a guard call out
    # here would read an unlocked row and could disagree with the claim that follows it.
    #
    # `override: true` takes §8.1's branch: a different guard question, a claim from `pending`,
    # `overridden_at`, and an `overridden` event carrying the shortfall. `Commands::Override` is
    # the named entry point a host calls for it (Q7).
    class Execute < Base
      def self.call(request:, actor:, override: false, reason: nil)
        new(request: request, actor: actor, override: override, reason: reason).call
      end

      def perform
        Execution::Runner.call(request: request, actor: actor,
                               override: options[:override], reason: options[:reason])
      end

      # Base locks around `perform`; §8 forbids holding one across T2. Create overrides this too,
      # for the opposite reason - it has no row to lock until it has written one.
      def around_perform
        yield
      end
    end
  end
end
