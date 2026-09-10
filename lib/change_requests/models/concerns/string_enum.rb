# frozen_string_literal: true

module ChangeRequests
  module Concerns
    # Enumerated columns are strings, not PostgreSQL enums (§5.7): a PG enum makes migrations depend
    # on application config at migration time and needs a hand-written `ALTER TYPE … ADD VALUE` per
    # new value, and it buys nothing here.
    #
    # So each one is a `string` column plus an inclusion validation plus a CHECK constraint in the
    # generated migration. This declares the first two and the conveniences that come with them:
    #
    #   string_enum :status, %w(pending satisfied closed rejected)
    #
    #   Stage.statuses          # => ["pending", "satisfied", "closed", "rejected"]
    #   stage.pending?          # => true
    #   Stage.pending           # => a scope
    #
    # Rails' own `enum` is deliberately not used. It wants to own the column's reader and writer, it
    # maps values through a hash, and it raises on an unknown value at assignment rather than
    # reporting it as a validation error - none of which suits a column whose whole point is to be a
    # plain, legible string in the database.
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
