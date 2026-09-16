# frozen_string_literal: true

module ChangeRequests
  module Value
    Field = Data.define(:key, :label, :value) do
      def initialize(key:, value:, label: nil)
        super(key: key, value: value, label: label || Value.label(:fields, key))
      end
    end
  end
end
