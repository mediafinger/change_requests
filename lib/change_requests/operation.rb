# frozen_string_literal: true

module ChangeRequests
  # One declared operation: what a request against it will invoke, how it may be retried, and the
  # workflow it materialises (§6.4). Declaring this is what buys the dispatch allowlist, the
  # snapshot-on-create and the policy-not-caller-input guarantee of §6.12.
  #
  # M2 adds `op.workflow`, `op.cooldown`, `op.override` and `Operations#verify!`.
  class Operation
    # change_request_stages.name is NOT NULL, and the shorthand declares no stage of its own.
    DEFAULT_STAGE_NAME = "approval"

    attr_reader :key, :workflow
    attr_accessor :version, :service, :payload_labels, :idempotent
    attr_writer :method_name, :max_attempts

    def initialize(key)
      @key            = key.to_s
      @method_name    = :call
      @idempotent     = false
      @payload_labels = nil
      @max_attempts   = nil
      @expires_in     = nil
      @expires_in_set = false
      @workflow       = Workflow.new
    end

    def method_name
      @method_name&.to_sym
    end

    # The two defaults below resolve lazily: initializer order is the host's, and an operations file
    # that loads before the configuration file should still see the host's defaults.
    def max_attempts
      @max_attempts || ChangeRequests.config.default_max_attempts
    end

    def expires_in
      return @expires_in if @expires_in_set

      ChangeRequests.config.default_expires_in
    end

    # nil is a value here, not an absence: it means this operation never expires, whatever the
    # host-wide default says.
    def expires_in=(value)
      @expires_in_set = true
      @expires_in     = value
    end

    # The §6.4 shorthand: one stage, one quorum, no ceremony. Replaces any previous description -
    # it is "the approval rule for this operation", not one of several.
    def approvals(permissions: nil, actor_type: nil, eligible_actors: nil, match: nil, required: 1)
      quorum = build_quorum(permissions: permissions, actor_type: actor_type,
                            eligible_actors: eligible_actors, match: match, required: required)

      @workflow = Workflow.new(
        [Workflow::Stage.new(name: DEFAULT_STAGE_NAME, position: 1, satisfied_by: :any_quorum,
                             quorums: [quorum])]
      )
    end

    def validate!
      problems = self.problems

      return true if problems.empty?

      fail ConfigurationError,
           "ChangeRequests operation #{key.inspect} is misconfigured:\n- #{problems.join("\n- ")}"
    end

    def problems
      [version_problem].compact
    end

    private

    def version_problem
      return if version.respond_to?(:to_str) && !version.to_str.strip.empty?

      "op.version is #{version.inspect}. Every operation declares one, it is snapshotted onto " \
        "every request as a NOT NULL column, and the gem never judges its content (§5.10)."
    end

    def build_quorum(permissions:, actor_type:, eligible_actors:, match:, required:)
      rows   = permission_rows(permissions, actor_type)
      actors = list(eligible_actors)

      refuse_empty_eligibility if rows.empty? && actors.empty?
      refuse_threshold(required) unless required.is_a?(Integer) && required >= 1
      refuse_match(match) unless match.nil? || Configuration::PERMISSION_MATCHES.include?(match)

      Workflow::Quorum.new(name: nil, position: 1, threshold: required, permission_match: match,
                           permissions: rows, eligible_actors: actors)
    end

    def permission_rows(permissions, actor_type)
      entries = list(permissions)

      return [Workflow::Permission.new(permission: nil, actor_type: actor_type.to_s)] \
        if entries.empty? && actor_type

      entries.map { |entry| permission_row(entry, actor_type) }
    end

    def permission_row(entry, actor_type)
      return Workflow::Permission.new(permission: entry.to_s, actor_type: actor_type&.to_s) \
        unless entry.is_a?(Hash)

      Workflow::Permission.new(permission: entry[:permission]&.to_s,
                               actor_type: (entry[:actor_type] || actor_type)&.to_s)
    end

    # Array() would splat a Struct or a Hash into its members. Only a real array is one.
    def list(value)
      return [] if value.nil?

      Array.try_convert(value) || [value]
    end

    def refuse_empty_eligibility
      fail ConfigurationError,
           "ChangeRequests operation #{key.inspect}: op.approvals needs `permissions:`, " \
           "`actor_type:` or `eligible_actors:`. A quorum nobody qualifies for can never be " \
           "satisfied, and the request would sit pending until it expired (§5.3)."
    end

    def refuse_threshold(required)
      fail ConfigurationError,
           "ChangeRequests operation #{key.inspect}: op.approvals required: #{required.inspect}. " \
           "It must be an integer of at least 1 - one approval is the minimum, not zero."
    end

    def refuse_match(match)
      fail ConfigurationError,
           "ChangeRequests operation #{key.inspect}: op.approvals match: #{match.inspect}. " \
           "Expected #{Configuration::PERMISSION_MATCHES.map(&:inspect).join(" or ")} (§5.3)."
    end
  end
end
