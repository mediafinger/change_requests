# frozen_string_literal: true

module ChangeRequests
  module Concerns
    #   terminal_states :successful, :rejected, :canceled, :expired
    #
    # Floor beneath the commands: holds even when a caller bypasses them (§5.8). Reads status_was, so
    # the transition *into* a final state passes. Says nothing about events or attempts, which are
    # separate rows - commenting on a finished request is allowed (§5.5).
    module TerminalStateGuard
      extend ActiveSupport::Concern

      included do
        class_attribute :terminal_state_values, instance_writer: false, default: [].freeze

        before_update :refuse_updates_once_final
      end

      class_methods do
        def terminal_states(*values)
          self.terminal_state_values = (terminal_state_values + values.map(&:to_s)).uniq.freeze
        end
      end

      def final?
        terminal_state_values.include?(status)
      end

      private

      def refuse_updates_once_final
        previous_status = status_was

        return unless terminal_state_values.include?(previous_status)

        fail AlreadyFinalized.new(request: self, reason: :already_finalized)
      end
    end
  end
end
