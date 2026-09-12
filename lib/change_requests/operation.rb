# frozen_string_literal: true

module ChangeRequests
  # One declared operation: what a request against it will invoke, how it may be retried, and the
  # workflow it materialises (§6.4). Declaring this is what buys the dispatch allowlist, the
  # snapshot-on-create and the policy-not-caller-input guarantee of §6.12.
  #
  # M2 adds `op.cooldown`, `op.override` and `Operations#verify!`.
  class Operation
    attr_reader :key
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

    # Without a block, the reader `Commands::Create` walks. With one, the §6.4 / §6.9 declaration -
    # the only way to say who approves: ordered stages, each holding one inline quorum or a block of
    # named ones.
    #
    # Replaces any previous description - it is "the approval rule for this operation", not one of
    # several - and the new one is only installed once it has built without refusing.
    def workflow(&block)
      return @workflow unless block

      @workflow = Workflow::Builder.build(operation_key: key, &block)
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
  end
end
