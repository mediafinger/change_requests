# frozen_string_literal: true

module ChangeRequests
  module Commands
    # §6.10's break-glass entry point: `Execute` with `override: true`, and a name that says so.
    #
    #   Commands::Override.call(request:, actor:, reason: "Provider outage, CFO approved by phone")
    #
    # A thin wrapper on purpose (Q7). §8.1 wants the exception to look like one, and
    # `Execute.call(…, override: true)` buried in a controller does not. It also gives M5's
    # presenter two distinct actions to render - `:execute` and `:execute_override`, the second
    # `tone: :danger` and always confirmed - without branching on a boolean.
    #
    # A subclass rather than a delegation, so the rows and events it writes cannot drift from
    # `Execute(override: true)`: there is nothing here to drift.
    class Override < Execute
      def self.call(request:, actor:, reason: nil)
        new(request: request, actor: actor, override: true, reason: reason).call
      end
    end
  end
end
