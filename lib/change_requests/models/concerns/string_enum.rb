# frozen_string_literal: true

module ChangeRequests
  module Concerns
    # String column + inclusion validation; the migration adds the matching CHECK (§5.7). No PG enum:
    # ALTER TYPE per new value, for nothing.
    #
    #   string_enum :status, %w(pending satisfied closed)
    #   Stage.statuses #=> [...]   Stage.pending #=> scope   stage.pending? #=> true
    #
    # Not Rails' enum: no generated writer, no mapping hash, no dangerous-name collision check, and
    # no class-level constant. An out-of-range value is assigned as given and reported by the
    # inclusion validation; the CHECK constraint is the floor beneath that.
    module StringEnum
      extend ActiveSupport::Concern

      class_methods do
        def string_enum(column, values)
          values = values.map(&:to_s).freeze

          define_singleton_method(:"#{column.to_s.pluralize}") { values }

          validates column, inclusion: { in: values }, presence: true

          values.each do |value|
            scope value, -> { where(column => value) }

            define_method(:"#{value}?") { self[column] == value }
          end
        end
      end
    end
  end
end
