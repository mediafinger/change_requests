# frozen_string_literal: true

module ChangeRequests
  # Only the settings Milestone 1 reads. Execution, notification and UI keys arrive with the
  # milestones that consult them.
  class Configuration
    LABEL_STRATEGIES    = %i(live snapshot).freeze
    PERMISSION_MATCHES  = %i(any all).freeze
    EXECUTION_MODES     = %i(inline background).freeze

    # Identity (§9.1)
    attr_reader :actor_types, :tenant_types
    attr_accessor :actor_label_strategy, :actor_identity

    # Tenancy and visibility (§9.3). Both optional, both written against the `tenant_type` and
    # `tenant_id` string columns rather than a foreign key.
    attr_accessor :tenant_for
    attr_writer :visible_scope

    # Authorization (§9.2)
    attr_reader :authorization
    # The default only; every quorum carries its own (§5.3).
    attr_accessor :default_permission_match

    # Separation of duties (§8, §8.1)
    attr_accessor :approver_may_execute, :requester_may_execute, :requester_may_override

    # Workflow and execution defaults (§7.1, §8)
    attr_accessor :only_record_rejections, :default_max_attempts, :default_expires_in

    # Where T2 and T3 run (§8, §10). `job_class` is a string so the gem never holds a class
    # reference across a reload, and so a headless host can name one it has not loaded.
    attr_accessor :execution_mode, :job_class, :job_queue

    # Presentation (§5.12, §10). The renderer takes `(request, view)`, so views call it, not presenters.
    attr_accessor :payload_preview_limit, :payload_renderer

    def initialize
      @actor_types  = {}
      @tenant_types = {}

      @actor_label_strategy = :live
      @actor_identity       = nil

      @tenant_for    = nil
      @visible_scope = nil

      @authorization            = Authorization::Permissions.new
      @default_permission_match = :any

      @requester_may_execute  = false
      @approver_may_execute   = true
      @requester_may_override = false

      @only_record_rejections = false
      @default_max_attempts   = 1
      @default_expires_in     = nil

      @execution_mode = :inline
      @job_class      = "ChangeRequests::Execution::Job"
      @job_queue      = :default

      @payload_preview_limit = 3
      @payload_renderer      = nil
    end

    # Defaults to tenant scoping when the gem can work out an actor's tenant, and to the identity
    # scope otherwise (§9.3).
    #
    # **`tenant_for` is what makes the default scope anything.** A host that registers a
    # `tenant_type` only to *record* the tenant - passing `tenant:` explicitly and never wanting
    # visibility narrowed - gets the identity scope, which is what not telling the gem how to find
    # an actor's tenant asks for. A host that wants scoping sets `tenant_for`, or replaces this
    # entirely.
    def visible_scope
      @visible_scope || default_visible_scope
    end

    # §9.2 tells hosts to assign a bare lambda; the gem needs one object answering `allows?`.
    def authorization=(policy)
      @authorization =
        if policy.respond_to?(:allows?) || !policy.respond_to?(:call)
          policy # validate! reports anything that answers neither
        else
          Authorization::Callable.new(policy)
        end
    end

    # Reopens an existing registration rather than replacing it: two initializers may each
    # contribute part of one.
    def actor_type(name)
      register(@actor_types, ActorType, name) { |type| yield(type) if block_given? }
    end

    def tenant_type(name)
      register(@tenant_types, TenantType, name) { |type| yield(type) if block_given? }
    end

    # Runs in the engine's after_initialize. Reports every problem at once, not one per boot.
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
        authorization_problem,
        max_attempts_problem,
        tenant_for_problem,
        visible_scope_problem,
        execution_mode_problem,
        job_class_problem,
        job_queue_problem,
        payload_preview_limit_problem,
        payload_renderer_problem,
        *actor_types.values.flat_map(&:problems),
        *tenant_types.values.flat_map(&:problems),
      ].compact
    end

    private

    # A real copy, not a shallow one: `actor_type` reopens an existing registration in place, so
    # sharing the hashes - or the registered objects in them - would share every mutation.
    def initialize_copy(source)
      super

      @actor_types   = @actor_types.transform_values(&:dup)
      @tenant_types  = @tenant_types.transform_values(&:dup)
      @authorization = @authorization.dup
    end

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

    def execution_mode_problem
      return if EXECUTION_MODES.include?(execution_mode)

      "config.execution_mode is #{execution_mode.inspect}. " \
        "Expected #{EXECUTION_MODES.map(&:inspect).join(" or ")} (§8)."
    end

    # Not checked for resolvability here: a headless process may legitimately have `:background`
    # configured and no ActiveJob at all, and refusing that would fail a boot that works. The
    # enqueue reports it instead - see ChangeRequests.background_job! (§8).
    def job_class_problem
      return if job_class.respond_to?(:to_str) && !job_class.to_str.strip.empty?

      "config.job_class is #{job_class.inspect}. Expected the name of an ActiveJob class, " \
        "for example \"ChangeRequests::Execution::Job\" (§10)."
    end

    def job_queue_problem
      return unless job_queue.nil? || job_queue.to_s.strip.empty?

      "config.job_queue is #{job_queue.inspect}. Expected a queue name (§10)."
    end

    def payload_preview_limit_problem
      return if payload_preview_limit.is_a?(Integer) && !payload_preview_limit.negative?

      "config.payload_preview_limit is #{payload_preview_limit.inspect}. Expected an integer of 0 or " \
        "more; 0 hides the preview (§5.12)."
    end

    def payload_renderer_problem
      return if payload_renderer.nil? || callable_with?(payload_renderer, 2)

      "config.payload_renderer is #{payload_renderer.inspect}. Expected nil, or something callable " \
        "taking the request and the view, such as " \
        "`->(request, view) { view.render \"admin/payload\", request: }` (§10)."
    end

    def default_visible_scope
      return ->(scope, _actor) { scope } if tenant_for.nil?

      lambda do |scope, actor|
        tenant = tenant_for.call(actor)

        next scope.none if tenant.nil?

        reference = ChangeRequests.actor_attributes(tenant, registry: :tenant_types)

        scope.where(tenant_type: reference[:type], tenant_id: reference[:id])
      end
    end

    def tenant_for_problem
      return if tenant_for.nil? || callable_with?(tenant_for, 1)

      "config.tenant_for is #{tenant_for.inspect}. Expected nil, or something callable taking the " \
        "actor, such as `->(actor) { actor.organization }` (§9.3)."
    end

    def visible_scope_problem
      return if @visible_scope.nil? || callable_with?(@visible_scope, 2)

      "config.visible_scope is #{@visible_scope.inspect}. Expected nil, or something callable " \
        "taking the scope and the actor, such as " \
        "`->(scope, actor) { scope.where(tenant_id: actor.organization_id.to_s) }` (§9.3)."
    end

    # A lambda's arity is exact and a method object's may be negative for splats, which is a
    # host's business rather than ours - only a definite mismatch is a problem.
    def callable_with?(subject, count)
      return false unless subject.respond_to?(:call)
      return true unless subject.respond_to?(:arity)

      subject.arity.negative? || subject.arity == count
    end

    def actor_identity_problem
      return if actor_identity.nil? || actor_identity.respond_to?(:call)

      "config.actor_identity is #{actor_identity.inspect}. Expected nil, or something callable " \
        "such as `->(actor) { actor.person_id }` (§9.4)."
    end

    def authorization_problem
      return if authorization.respond_to?(:allows?)

      "config.authorization is #{authorization.inspect}. Expected " \
        "ChangeRequests::Authorization::Permissions.new, another object answering " \
        "`allows?(actor:, quorum:)`, or a lambda taking (actor:, request:, stage:, action:) (§9.2)."
    end

    def max_attempts_problem
      return if default_max_attempts.is_a?(Integer) && default_max_attempts >= 1

      "config.default_max_attempts is #{default_max_attempts.inspect}. " \
        "It must be an integer of at least 1 - one attempt is the default, not zero."
    end
  end
end
