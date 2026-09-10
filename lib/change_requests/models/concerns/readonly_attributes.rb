# frozen_string_literal: true

module ChangeRequests
  module Concerns
    #   readonly_after_create :operation_key, :service, :payload
    #
    # Not Rails' attr_readonly: that discards the assignment silently unless the *host app* enabled
    # ActiveRecord.raise_on_assign_to_attr_readonly, which a gem cannot control (issue I4).
    # update_columns bypasses this, by design.
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
