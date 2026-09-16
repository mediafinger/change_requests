# frozen_string_literal: true

module ChangeRequests
  module Value
    StageProgress = Data.define(:name, :label, :position, :status, :satisfied, :current, :satisfied_by,
                                :satisfied_via, :remaining_options, :quorums) do
      def initialize(name:, position:, status:, satisfied:, current:, satisfied_by:, label: nil,
                     satisfied_via: nil, remaining_options: [], quorums: [])
        super(name: name, label: label || Value.label(:stages, name), position: position, status: status,
              satisfied: satisfied, current: current, satisfied_by: satisfied_by, satisfied_via: satisfied_via,
              remaining_options: remaining_options.dup.freeze, quorums: quorums.dup.freeze)
      end

      alias_method :satisfied?, :satisfied
      alias_method :current?, :current
    end
  end
end
