# frozen_string_literal: true

module ChangeRequests
  module Execution
    # §6.12's target contract, in one place: a **public singleton method** taking **keyword
    # arguments only**. `Operation#target_problems` reads it at boot and `Dispatcher` at dispatch,
    # so `verify!` and execution cannot word the same defect differently.
    #
    # Idempotence is the third half of the contract and is not here, because nothing can check it.
    class TargetContract
      # `:block` is not positional in the sense that matters - a target may take one and ignore it.
      POSITIONAL = %i(req opt rest).freeze
      KEYWORDS   = %i(key keyreq).freeze

      def self.problem(service:, method_name:)
        new(service: service, method_name: method_name).problem
      end

      # The constant, or a ConfigurationError carrying the same words `problem` would have returned.
      # A target that cannot be dispatched is a declaration error, not a target failure: retrying it
      # could never succeed, and M3a's retry ceiling exists for failures that might (§8).
      def self.target!(service:, method_name:)
        contract = new(service: service, method_name: method_name)
        problem  = contract.problem

        fail ConfigurationError, problem if problem

        contract.target
      end

      def initialize(service:, method_name:)
        @service     = service
        @method_name = method_name
      end

      def target
        @target ||= service.to_s.safe_constantize
      end

      def problem
        return unresolved_service if target.nil?
        return unanswered_method unless target.respond_to?(method_name)
        return positional_arguments if positional_parameters.any?

        nil
      end

      # Whether the target would accept this keyword: it declares it, or it forwards everything.
      def accepts?(keyword)
        parameters.any? do |kind, name|
          kind == :keyrest || (KEYWORDS.include?(kind) && name == keyword)
        end
      end

      private

      attr_reader :service, :method_name

      # A target answering through method_missing has no Method to inspect. Nothing can be proven
      # about its parameters, so nothing is claimed: an empty list refuses nothing.
      def parameters
        @parameters ||= target.method(method_name).parameters
      rescue NameError
        @parameters = []
      end

      def positional_parameters
        parameters.filter_map { |kind, name| name || kind if POSITIONAL.include?(kind) }
      end

      def unresolved_service
        "op.service is #{service.inspect}, which does not resolve to a constant. Execution " \
          "dispatches through the declaration, never through the strings on the row (§6.12 point 1)."
      end

      def unanswered_method
        "#{service} does not answer .#{method_name}. Dispatch calls the public singleton method, so " \
          "an instance method of the same name is not the one it will reach (§6.12)."
      end

      def positional_arguments
        "#{service}.#{method_name} takes positional arguments " \
          "(#{positional_parameters.join(", ")}). A change-request target accepts keyword arguments " \
          "only - the payload is dispatched as `**payload.symbolize_keys` (§6.12)."
      end
    end
  end
end
