# frozen_string_literal: true

module ChangeRequests
  module Value
    # Labelled under `timeline`, not `events`: that key holds the bodies the gem writes (§5.11).
    TimelineEntry = Data.define(:kind, :label, :actor, :body, :metadata, :occurred_at, :operation_version) do
      def initialize(kind:, actor:, occurred_at:, operation_version:, label: nil, body: nil, metadata: {})
        super(kind: kind, label: label || Value.label(:timeline, kind), actor: actor, body: body,
              metadata: metadata.dup.freeze, occurred_at: occurred_at, operation_version: operation_version)
      end
    end
  end
end
