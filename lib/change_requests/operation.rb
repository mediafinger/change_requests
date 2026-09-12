# frozen_string_literal: true

module ChangeRequests
  # One declared operation: what a request against it will invoke, how it may be retried, and the
  # workflow it materialises (§6.4). Declaring this is what buys the dispatch allowlist, the
  # snapshot-on-create and the policy-not-caller-input guarantee of §6.12.
  #
  # `op.cooldown` arrives with M9b.
  class Operation
    attr_reader :key, :override_policy
    attr_accessor :version, :service, :payload_labels
    attr_writer :method_name, :max_attempts

    def initialize(key)
      @key            = key.to_s
      @method_name    = :call
      @payload_labels = nil
      @max_attempts   = nil
      @expires_in     = nil
      @expires_in_set = false
      @override_policy = nil
      @workflow = Workflow.new
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

    # §6.10's break-glass opt-in. Declared, never defaulted: no override exists until a host
    # writes this line. The reader is `override_policy` rather than this method - with no block to
    # disambiguate, one name cannot both declare and report, and a bare `op.override` that read
    # instead of declaring would silently leave the gate shut.
    def override(permissions: nil, require_reason: false)
      @override_policy = Override.new(permissions: list(permissions).map(&:to_s),
                                      require_reason: require_reason ? true : false)
    end

    def overridable?
      !override_policy.nil?
    end

    def validate!
      problems = self.problems

      return true if problems.empty?

      fail ConfigurationError,
           "ChangeRequests operation #{key.inspect} is misconfigured:\n- #{problems.join("\n- ")}"
    end

    # Everything checkable without loading the host's classes. One implementation, three readers:
    # `validate!` at declaration, `Commands::Create` at creation and `Operations#verify!` at boot,
    # so none of them can disagree about what a complete declaration is (§7.2 †, §6.12 point 6).
    def problems
      [version_problem, service_problem, method_name_problem, workflow_problem,
       *threshold_problems].compact
    end

    # What needs the host's classes loaded, so it runs at boot and nowhere else: the §6.12 target
    # contract, in the words `Execution::Dispatcher` would use for the same defect.
    def target_problems
      return [] if service.blank? || !method_name_declared?

      [Execution::TargetContract.problem(service: service, method_name: method_name)].compact
    end

    private

    def version_problem
      return if version.respond_to?(:to_str) && !version.to_str.strip.empty?

      "op.version is #{version.inspect}. Every operation declares one, it is snapshotted onto " \
        "every request as a NOT NULL column, and the gem never judges its content (§5.10)."
    end

    # Array() would splat a Struct or a Hash into its members. Only a real array is one.
    def list(value)
      return [] if value.nil?

      Array.try_convert(value) || [value]
    end

    def service_problem
      return if service.present?

      "it declares no service, so nothing could ever execute it - set `op.service`"
    end

    # `attr_writer :method_name` can assign the documented :call default away (§6.12). Reported
    # here, so verify! names the declaration rather than respond_to? raising on nil.
    def method_name_problem
      return if method_name_declared?

      "op.method_name is #{@method_name.inspect}. Dispatch calls the public singleton method of " \
        "that name, and it defaults to :call - assigning nil takes the default away (§6.12)."
    end

    def method_name_declared?
      method_name.to_s.strip.present?
    end

    def workflow_problem
      return unless workflow.empty?

      "it declares no approvals, so a request could never be approved - declare `op.workflow`"
    end

    # The DSL refuses these at declaration. Re-checked so one call reports everything, and so a
    # hand-built description cannot enter the registry unnoticed.
    def threshold_problems
      workflow.stages.flat_map do |stage|
        stage.quorums.filter_map { |quorum| threshold_problem(stage, quorum) }
      end
    end

    def threshold_problem(stage, quorum)
      return if quorum.threshold.is_a?(Integer) && quorum.threshold >= 1

      "#{describe(stage, quorum)} has threshold #{quorum.threshold.inspect}. " \
        "One approval is the minimum, not zero (§5.3)."
    end

    def describe(stage, quorum)
      return "stage #{stage.name.to_sym.inspect}" if quorum.name.nil?

      "stage #{stage.name.to_sym.inspect} quorum #{quorum.name.to_sym.inspect}"
    end
  end
end
