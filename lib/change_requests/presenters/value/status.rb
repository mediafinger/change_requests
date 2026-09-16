# frozen_string_literal: true

module ChangeRequests
  module Value
    Status = Data.define(:key, :label, :tone, :tooltip) do
      def initialize(key:, tone:, label: nil, tooltip: nil)
        super(key: key, label: label || Value.label(:statuses, key), tone: Value.tone!(tone), tooltip: tooltip)
      end
    end
  end
end
