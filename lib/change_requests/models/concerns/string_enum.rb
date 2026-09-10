# frozen_string_literal: true

module ChangeRequests
  module Concerns
    # String column + inclusion validation; the migration adds the matching CHECK (§5.7). No PG enum:
    # ALTER TYPE per new value, for nothing.
    #
    #   string_enum :status, %w(pending satisfied closed)
    #   Stage.statuses #=> [...]   Stage.pending #=> scope   stage.pending? #=> true
    #
    # Not Rails' enum: it owns the reader and writer, maps through a hash, and raises at assignment
    # instead of reporting a validation error.
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
