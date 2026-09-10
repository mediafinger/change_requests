# frozen_string_literal: true

module ChangeRequests
  # `ChangeRequests.config` always returns a memoised instance, never nil; `configure` mutates it in
  # place, so declarations may be split across several initializers (§10).
  #
  # Only the settings Milestone 1 reads are here. Execution, notification and UI keys arrive with
  # the milestones that read them - a setting nothing consults yet is a promise the gem cannot keep.
  class Configuration
    LABEL_STRATEGIES    = %i(live snapshot).freeze
    PERMISSION_MATCHES  = %i(any all).freeze

    # Identity (§9.1)
    attr_reader :actor_types, :tenant_types
    attr_accessor :actor_label_strategy, :actor_identity

    # Authorization (§9.2)
    attr_accessor :authorization, :default_permission_match

    # Separation of duties (§8). `requester_may_approve` and `requester_may_override` are not here:
    # they are hard-wired false and only exist to refuse assignment.
    attr_accessor :requester_may_execute, :approver_may_execute

    # Workflow and execution defaults (§7.1, §8)
    attr_accessor :only_record_rejections, :default_max_attempts, :default_expires_in

    def initialize
      @actor_types  = {}
      @tenant_types = {}

      @actor_label_strategy = :live
      @actor_identity       = nil

      @authorization            = Authorization::Permissions.new
      @default_permission_match = :any

      @requester_may_execute = false
      @approver_may_execute  = true

      @only_record_rejections = false
      @default_max_attempts   = 1
      @default_expires_in     = nil
    end

    # Registers an actor class, or reopens one already registered so that settings accumulate rather
    # than replace - two initializers may each contribute part of the same registration.
    def actor_type(name)
      register(@actor_types, ActorType, name) { |type| yield(type) if block_given? }
    end

    def tenant_type(name)
      register(@tenant_types, TenantType, name) { |type| yield(type) if block_given? }
    end

    # Hard-wired false: a requester who can approve their own request has not been slowed down by
    # the gem at all (§8, §19.14). Guards compare identity directly and never read this.
    def requester_may_approve = false

    def requester_may_approve=(_value)
      fail ConfigurationError,
           "config.requester_may_approve is hard-wired false: a requester approving their own " \
           "request defeats four-eyes, which is the gem's central promise. Remove the assignment."
    end

    # Hard-wired false for the same reason: an override by the requester is a total bypass rather
    # than an accountable exception (§8.1).
    def requester_may_override = false

    def requester_may_override=(_value)
      fail ConfigurationError,
           "config.requester_may_override is hard-wired false: a requester who can override their " \
           "own request has not been slowed down at all. Remove the assignment."
    end

    # Runs in the engine's `after_initialize` (§10). Reports every problem at once, so one boot
    # fixes one round of mistakes rather than one mistake per boot.
    def validate!
      problems = self.problems

      return true if problems.empty?

      fail ConfigurationError, "ChangeRequests is misconfigured:\n- #{problems.join("\n- ")}"
    end

    def problems
      [
        actor_types_problem,
        label_strategy_problem,
        permission_match_problem,
        actor_identity_problem,
        max_attempts_problem,
        *actor_types.values.flat_map(&:problems),
        *tenant_types.values.flat_map(&:problems),
      ].compact
    end

    private

    def register(registry, klass, name)
      type = (registry[name.to_s] ||= klass.new(name))
      yield(type)

      type
    end

    def actor_types_problem
      return unless actor_types.empty?

      "No actor types are registered, so nothing may request or approve. Register at least one: " \
        "`config.actor_type \"User\" { |t| t.label = ->(u) { u.name } }` (§9.1)."
    end

    def label_strategy_problem
      return if LABEL_STRATEGIES.include?(actor_label_strategy)

      "config.actor_label_strategy is #{actor_label_strategy.inspect}. " \
        "Expected #{LABEL_STRATEGIES.map(&:inspect).join(" or ")} (§19.5)."
    end

    def permission_match_problem
      return if PERMISSION_MATCHES.include?(default_permission_match)

      "config.default_permission_match is #{default_permission_match.inspect}. " \
        "Expected #{PERMISSION_MATCHES.map(&:inspect).join(" or ")} (§5.3)."
    end

    def actor_identity_problem
      return if actor_identity.nil? || actor_identity.respond_to?(:call)

      "config.actor_identity is #{actor_identity.inspect}. Expected nil, or something callable " \
        "such as `->(actor) { actor.person_id }` (§9.4)."
    end

    def max_attempts_problem
      return if default_max_attempts.is_a?(Integer) && default_max_attempts >= 1

      "config.default_max_attempts is #{default_max_attempts.inspect}. " \
        "It must be an integer of at least 1 - one attempt is the default, not zero."
    end
  end
end
