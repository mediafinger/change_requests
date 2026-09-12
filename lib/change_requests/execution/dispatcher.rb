# frozen_string_literal: true

module ChangeRequests
  module Execution
    # §6.12 points 1-2: the allowlist dispatch, and §8's T2 - the one step that holds no row lock.
    #
    #   Dispatcher.call(operation_key: "members.update_roles", payload:, change_request_id:)
    #
    # It takes a **key**, never a request row. `operation_key -> (service, method_name)` resolves
    # from the live declaration, so the `service` and `method_name` columns stay audit data and a
    # careless endpoint that writes a row cannot choose what runs (§6.12 point 1).
    class Dispatcher
      def self.call(operation_key:, change_request_id:, payload: {})
        new(operation_key: operation_key, change_request_id: change_request_id, payload: payload).call
      end

      def initialize(operation_key:, change_request_id:, payload: {})
        @operation_key     = operation_key.to_s
        @change_request_id = change_request_id
        @payload           = payload
      end

      # Whatever the target returns. §8's T3 records the outcome; this step only runs it.
      def call
        target.public_send(operation.method_name, **arguments)
      end

      private

      attr_reader :operation_key, :change_request_id, :payload

      # Before anything is constantized: an undeclared key never reaches a target name at all, and
      # §5.11 words it the same way `Commands::Create` does.
      def operation
        return @operation if @operation

        declaration = ChangeRequests.operations[operation_key]

        fail UnknownOperation, "No operation is declared for #{operation_key.inspect} (§5.11)." if declaration.nil?

        @operation = declaration
      end

      def contract
        @contract ||= TargetContract.new(service: operation.service, method_name: operation.method_name)
      end

      def target
        @target ||= TargetContract.target!(service: operation.service, method_name: operation.method_name)
      end

      # Top-level only, because that is what round-trips through jsonb: a nested hash keeps its
      # string keys, and a target taking one should expect them (§6.12).
      def arguments
        keywords = validated_payload.symbolize_keys

        return keywords unless contract.accepts?(:change_request_id)

        # Ours wins over a payload key of the same name: it is the identity the gem guarantees is
        # stable across every attempt, which is the whole reason a target would want it (§8).
        keywords.merge(change_request_id: change_request_id)
      end

      def validated_payload
        return payload if payload.is_a?(Hash)

        fail InvalidPayload,
             "payload must be a JSON object, got #{payload.class}. It is dispatched as " \
             "`**payload.symbolize_keys`, so its keys become the target's keyword arguments (§6.12)."
      end
    end
  end
end
