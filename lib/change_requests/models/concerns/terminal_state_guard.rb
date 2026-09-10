# frozen_string_literal: true

module ChangeRequests
  module Concerns
    # Terminal-state protection at the model layer (§5.8):
    #
    #   terminal_states :successful, :rejected, :canceled, :expired
    #
    # A row whose status was already final refuses every further update, so the rule holds even when
    # a caller bypasses the commands entirely. The commands are where the good error messages live;
    # this is the floor beneath them.
    #
    # Two things it deliberately does not do:
    #
    #   * It does not block the transition *into* a final state. The check reads `status_was`, the
    #     value the row had before this save, so `pending → canceled` passes and `canceled →`
    #     anything does not.
    #   * It does not stop an audit trail growing. Events and attempts are their own rows, and
    #     commenting on a finished request is the point of having one (§5.5).
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
