# frozen_string_literal: true

module ChangeRequests
  module Value
    Quorum = Data.define(:name, :label, :required, :approved, :satisfied, :approvers) do
      def initialize(name:, required:, approved:, satisfied:, label: nil, approvers: [])
        super(name: name, label: label || label_for(name), required: required, approved: approved,
              satisfied: satisfied, approvers: approvers.dup.freeze)
      end

      alias_method :satisfied?, :satisfied

      private

      # A nameless quorum is its stage's only one, and ChangeRequests::Quorum#label answers with the
      # stage's label. Humanizing nil would render an empty heading instead.
      def label_for(name)
        fail ArgumentError, "a nameless quorum has no label of its own; pass its stage's label" if name.blank?

        Value.label(:quorums, name)
      end
    end
  end
end
