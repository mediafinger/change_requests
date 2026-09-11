# frozen_string_literal: true

module ChangeRequests
  module Commands
    # Takes one actor's decision back (§7.1).
    #
    #   Commands::Unapprove.call(request:, actor: current_user)
    #
    # The row goes; the trail does not. `Event` is append-only, so the `approved` event stays beside
    # the `unapproved` one and the timeline records both decisions (§5.5).
    class Unapprove < Base
      def self.call(request:, actor:)
        new(request: request, actor: actor).call
      end

      def perform
        guard = Guards::Unapprove.new(request: request, actor: actor)
        guard.check!

        decision = guard.decision
        # Read before the row goes: the links are gone a line later.
        metadata = metadata_for(decision)

        # Deleting the approval is what removes its quorum links: ApprovalQuorum is Immutable, so
        # `decision.quorums.destroy_all` - the obvious code - raises ReadOnlyRecord. The
        # association carries no `dependent:`, and the database cascades (Q15).
        decision.destroy!

        emit(:unapproved, metadata: metadata)

        # Commands::EvaluateWorkflow is M1b-12. Until it lands nothing re-counts the stage.
        request
      end

      private

      # Names what was retracted and where. Without it, a request that gained and lost the same
      # approval twice would leave two indistinguishable pairs in the timeline (§5.9).
      def metadata_for(decision)
        metadata = { stage: decision.stage.name, decision: decision.decision }
        names = decision.quorums.map(&:name).compact

        metadata[:quorums] = names if names.any?

        metadata
      end
    end
  end
end
