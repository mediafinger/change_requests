# frozen_string_literal: true

module ChangeRequests
  class Workflow
    # The `q` of `w.stage :name do |q| … end`, and the one place a declared quorum becomes a
    # Workflow::Quorum. The single-quorum stage shorthand routes through it too, so one
    # normalisation and one set of refusals serve both forms (§5.3, §6.9).
    class StageBuilder
      attr_reader :quorums

      def initialize(operation_key:, stage_name:)
        @operation_key = operation_key
        @stage_name    = stage_name
        @quorums       = []
      end

      def quorum(name = nil, permissions: nil, actor_type: nil, eligible_actors: nil, match: nil, threshold: 1)
        quorum_name = name&.to_s
        rows        = permission_rows(permissions, actor_type)
        actors      = list(eligible_actors)

        refuse_name(quorum_name)
        refuse_empty_eligibility(quorum_name) if rows.empty? && actors.empty?
        refuse_threshold(quorum_name, threshold) unless threshold.is_a?(Integer) && threshold >= 1
        refuse_match(quorum_name, match) unless match.nil? || Configuration::PERMISSION_MATCHES.include?(match)

        @quorums << Quorum.new(name: quorum_name, position: @quorums.size + 1, threshold: threshold,
                               permission_match: match, permissions: rows, eligible_actors: actors)
      end

      private

      attr_reader :operation_key, :stage_name

      def permission_rows(permissions, actor_type)
        entries = list(permissions)

        return [Permission.new(permission: nil, actor_type: actor_type.to_s)] if entries.empty? && actor_type

        entries.map { |entry| permission_row(entry, actor_type) }
      end

      def permission_row(entry, actor_type)
        return Permission.new(permission: entry.to_s, actor_type: actor_type&.to_s) unless entry.is_a?(Hash)

        Permission.new(permission: entry[:permission]&.to_s,
                       actor_type: (entry[:actor_type] || actor_type)&.to_s)
      end

      # Array() would splat a Struct or a Hash into its members. Only a real array is one.
      def list(value)
        return [] if value.nil?

        Array.try_convert(value) || [value]
      end

      # A nameless quorum is the single-quorum shorthand written out (§5.9). Once a stage holds a
      # second one, "which quorum was satisfied" becomes a question the metadata has to answer.
      def refuse_name(quorum_name)
        return if quorums.empty? && quorum_name.nil?

        refuse_unnamed if quorum_name.nil? || quorums.any? { |declared| declared.name.nil? }
        refuse_duplicate(quorum_name) if quorums.any? { |declared| declared.name == quorum_name }
      end

      def context(quorum_name = nil)
        return "op.workflow stage #{stage_name.to_sym.inspect}" if quorum_name.nil?

        "op.workflow stage #{stage_name.to_sym.inspect} quorum #{quorum_name.to_sym.inspect}"
      end

      def prefix
        "ChangeRequests operation #{operation_key.inspect}"
      end

      def refuse_unnamed
        fail ConfigurationError,
             "#{prefix}: #{context} holds more than one quorum, so each of them needs a name. " \
             "That name is what a stage_satisfied event reports and what a test matcher asks for (§5.9)."
      end

      def refuse_duplicate(quorum_name)
        fail ConfigurationError,
             "#{prefix}: #{context} declares quorum #{quorum_name.to_sym.inspect} twice. Quorum names are " \
             "unique within their stage, and the unique index would refuse the second row (§5.3)."
      end

      def refuse_empty_eligibility(quorum_name)
        fail ConfigurationError,
             "#{prefix}: #{context(quorum_name)} needs `permissions:`, `actor_type:` or " \
             "`eligible_actors:`. A quorum nobody qualifies for can never be satisfied, and the " \
             "request would sit pending until it expired (§5.3)."
      end

      def refuse_threshold(quorum_name, threshold)
        fail ConfigurationError,
             "#{prefix}: #{context(quorum_name)} threshold: #{threshold.inspect}. " \
             "It must be an integer of at least 1 - one approval is the minimum, not zero."
      end

      def refuse_match(quorum_name, match)
        fail ConfigurationError,
             "#{prefix}: #{context(quorum_name)} match: #{match.inspect}. " \
             "Expected #{Configuration::PERMISSION_MATCHES.map(&:inspect).join(" or ")} (§5.3)."
      end
    end
  end
end
