# frozen_string_literal: true

module ChangeRequests
  # The declaration registry (§6.12): the dispatch allowlist, and the only source of approval
  # policy. `ChangeRequests.operations` is the one instance a host declares into.
  #
  # M2 adds `verify!` and `ChangeRequests.request!`.
  class Operations
    def initialize
      @operations = {}
    end

    def define(key)
      unless block_given?
        fail ArgumentError, "ChangeRequests.operations.define(#{key.inspect}) needs a block: " \
                            "`define(#{key.inspect}) { |op| op.version = \"…\" }`"
      end

      operation = Operation.new(key)
      yield(operation)
      operation.validate!

      @operations[operation.key] = operation
    end

    # nil, not a raise: every guard asks whether the declaration is still live, and §5.11 makes
    # that a refusal the guard words itself.
    def [](key)
      @operations[key.to_s]
    end

    def keys
      @operations.keys
    end

    def each(&)
      @operations.each_value(&)
    end

    def clear
      @operations.clear
    end

    # Boot-time verification (§6.12 point 6), run by `rake change_requests:verify` and by the
    # engine's to_prepare hook in development. One raised error listing every problem, the shape
    # `Configuration#validate!` already uses (Q4).
    def verify!
      problems = self.problems

      return true if problems.empty?

      fail ConfigurationError,
           "ChangeRequests operations are misconfigured:\n- #{problems.join("\n- ")}"
    end

    def problems
      @operations.each_value.flat_map do |operation|
        (operation.problems + operation.target_problems).map { |problem| "#{operation.key}: #{problem}" }
      end
    end

    private

    def initialize_copy(source)
      super

      @operations = @operations.dup
    end
  end
end
