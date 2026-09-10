# frozen_string_literal: true

module ChangeRequests
  class Configuration
    # What `config.actor_type` and `config.tenant_type` have in common: a host class the gem is
    # allowed to reference, the type of its primary key, and how to turn one of its records into a
    # label (§9.1, §10).
    #
    # The registration list is simultaneously the `*_type` allowlist (§5.7 consequence 5), the label
    # source and the per-type key cast - so a typo fails at boot rather than at render time.
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
