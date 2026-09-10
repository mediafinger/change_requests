# frozen_string_literal: true

module ChangeRequests
  class Configuration
    # Shared by actor_type and tenant_type. The registration list is at once the `*_type` allowlist
    # (§5.7), the label source and the per-type key cast, so a typo fails at boot.
    class RegisteredType
      KEY_TYPES = %i(uuid integer string).freeze

      attr_reader :name
      attr_accessor :key_type, :label

      def initialize(name)
        @name     = name.to_s
        @key_type = :integer
        @label    = nil
      end

      # Returns an array of human-readable problems; empty when the registration is sound.
      def problems
        [key_type_problem, label_problem].compact
      end

      private

      def key_type_problem
        return if KEY_TYPES.include?(key_type)

        "#{describe} has key_type #{key_type.inspect}. " \
          "Expected one of #{KEY_TYPES.map(&:inspect).join(", ")}."
      end

      def label_problem
        return if label.respond_to?(:call)

        "#{describe} needs a label, for example " \
          "`t.label = ->(record) { record.name }`. Labels are snapshotted onto every request, " \
          "approval and event, so a request stays readable after the record is deleted (§5.7)."
      end

      def describe
        "#{self.class.name.split("::").last} #{name.inspect}"
      end
    end
  end
end
