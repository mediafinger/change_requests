# frozen_string_literal: true

module ChangeRequests
  module Concerns
    # Creation-time facts that must not change afterwards (§5.1):
    #
    #   readonly_after_create :operation_key, :service, :payload, :requester_label
    #
    # Deliberately **not** Rails' `attr_readonly`. That discards the assignment in silence unless the
    # host application has `ActiveRecord.raise_on_assign_to_attr_readonly` enabled - a global setting
    # a gem cannot control and a host can turn off. The whole point of this list is that a snapshot
    # cannot drift, so silence is the one outcome it must not have (issue I4).
    #
    # Raising from `before_update` also means the guard holds for every path that reaches the
    # database - `update_columns` excepted, which bypasses callbacks by design and is nobody's
    # accident.
    module ReadonlyAttributes
      extend ActiveSupport::Concern

      included do
        class_attribute :readonly_after_create_attributes, instance_writer: false, default: [].freeze

        before_update :refuse_changes_to_readonly_attributes
      end

      class_methods do
        def readonly_after_create(*names)
          self.readonly_after_create_attributes = (readonly_after_create_attributes + names.map(&:to_s)).uniq.freeze
        end
      end

      private

      def refuse_changes_to_readonly_attributes
        changed_readonly = changed & readonly_after_create_attributes

        return if changed_readonly.empty?

        fail ReadonlyAttribute,
             "#{self.class.name}##{changed_readonly.join(", #")} #{changed_readonly.one? ? "is" : "are"} " \
             "set at creation and cannot be changed (§5.1)"
      end
    end
  end
end
