# frozen_string_literal: true

module ChangeRequests
  module Value
    # Labelled under `timeline`, not `events`: that key holds the bodies the gem writes (§5.11).
    #
    # `body` is what the actor wrote; `detail` is what the gem reads out of `metadata` for the kinds that
    # have something to say - the quorum met, the shortfall bypassed, the attempt written off (M5-5).
    TimelineEntry = Data.define(:kind, :label, :actor, :body, :detail, :metadata, :occurred_at,
                                :operation_version) do
      def initialize(kind:, actor:, occurred_at:, operation_version:, label: nil, body: nil, detail: nil, metadata: {})
        super(kind: kind, label: label || Value.label(:timeline, kind), actor: actor, body: body, detail: detail,
              metadata: metadata.dup.freeze, occurred_at: occurred_at, operation_version: operation_version)
      end
    end
  end
end
