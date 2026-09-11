# frozen_string_literal: true

module ChangeRequests
  module Guards
    # One guard object, consulted by both the command and the presenter, so a disabled button and a
    # raised error cannot disagree about why something is refused (§7).
    #
    #   class Approve < Base
    #     refuses_with NotApprovable
    #
    #     def refusal
    #       return :not_pending unless request.pending?
    #       ...
    #     end
    #   end
    #
    # Subclasses implement `refusal` and return nil when they permit the transition. The
    # undeclared-operation check runs first, here, so no guard has to repeat it (§5.11).
    class Base
      # The shared vocabulary. `reason` is the contract - controllers branch on these symbols and
      # views render them as a disabled button's tooltip - so a guard picks one from this list
      # rather than inventing wording. M1b-13 translates every entry.
      REASONS = %i(
        operation_undeclared
        not_pending
        requester
        stage_not_current
        stage_not_open
        already_decided
        not_the_approver
        not_permitted
        already_finalized
        executing
        reason_required
        may_not_request
        not_approved
        attempts_exhausted
        not_expired
        not_system
      ).freeze

      attr_reader :request, :actor, :options

      class_attribute :declared_error_class, instance_accessor: false
      class_attribute :exempt_from_undeclared_operation, instance_accessor: false, default: false

      class << self
        # Declared, never derived from the guard's name: Create, Comment and Expire refuse with
        # NotAuthorized, the rest with their own TransitionError.
        def refuses_with(error_class)
          self.declared_error_class = error_class
        end

        def error_class
          declared_error_class ||
            fail(ConfigurationError, "#{name} must declare `refuses_with <error class>` (§7)")
        end

        # Comment only. A request stranded by a removed declaration is exactly the one someone needs
        # to leave a note on, and a comment writes no lifecycle state (§5.11, I8).
        def exempt_from_undeclared_operation!
          self.exempt_from_undeclared_operation = true
        end
      end

      def initialize(request:, actor:, **options)
        @request = request
        @actor   = actor
        @options = options
      end

      def allowed?
        reason.nil?
      end

      def reason
        return :operation_undeclared if operation.nil? && !self.class.exempt_from_undeclared_operation

        refusal
      end

      # One shared rule beside the declared class: a request that is already over is the same
      # refusal whichever command met it, and the model's TerminalStateGuard raises exactly this
      # with exactly this reason (§5.8). A host rescuing AlreadyFinalized catches both.
      REASON_ERRORS = { already_finalized: AlreadyFinalized }.freeze

      def check!
        return request if allowed?

        fail error_for(reason).new(request: request, reason: reason)
      end

      # Subclasses override. nil permits.
      def refusal
        nil
      end

      def config
        ChangeRequests.config
      end

      # Resolved live, never from the columns on the row: those are audit data, and a request whose
      # operation is no longer declared can never run (§6.12).
      def operation
        ChangeRequests.operations[request.operation_key]
      end

      def stage
        request.current_stage
      end

      # Pluggable: the permission rows by default, or the host's own policy (§9.2).
      def authorization
        config.authorization
      end

      # The quorums of the current stage this actor qualifies for - the same predicate
      # Request.awaiting_approval_from runs in SQL (§5.3). Shared by every guard that asks whether
      # someone is an eligible approver: Approve, Reject, Cancel and Comment.
      def eligible_quorums
        @eligible_quorums ||= qualifying(stage&.quorums&.pending)
      end

      # §7.2's preamble: "eligible approver" means eligible for at least one quorum on *any* stage of
      # this request, by permission or by name. A stage-three director may cancel or comment on a
      # request sitting in stage one. Approve and Reject are the narrower, current-stage question.
      def eligible_approver?
        eligible_quorums.any? || eligible_on_another_stage?
      end

      # §6.9: a stage-three director sitting on a stage-one request is told to wait, not refused.
      def eligible_on_another_stage?
        request.stages.where.not(id: stage&.id).any? { |other| qualifying(other.quorums).any? }
      end

      # One decision per stage per person. When the host declares a shared identity it is used in
      # place of (type, id), so one human cannot decide twice through two actor classes (§9.4).
      def already_decided?
        return false if stage.nil?

        decided_by_reference? || decided_by_identity?
      end

      # The acting actor as the columns store them. Raises UnknownActorType for an unregistered
      # class, which is the allowlist doing its job (§9.1).
      def actor_ref
        @actor_ref ||= ChangeRequests.actor_attributes(actor)
      end

      # Is this the same human twice? `(type, id)` is airtight within one actor class and blind
      # across them, which `config.actor_identity` is the opt-in fix for (§9.4). Either side may be
      # a live actor object or a stored reference triple.
      def same_person?(one, other)
        return false if one.nil? || other.nil?

        left  = identity_of(one)
        right = identity_of(other)

        return left == right if left && right

        reference_of(one) == reference_of(other)
      end

      private

      def error_for(reason)
        REASON_ERRORS.fetch(reason) { self.class.error_class }
      end

      def qualifying(quorums)
        return [] if quorums.nil?

        quorums.select { |quorum| authorization.allows?(actor: actor, quorum: quorum) }
      end

      def decided_by_reference?
        stage.approvals.exists?(approver_type: actor_ref[:type], approver_id: actor_ref[:id])
      end

      def decided_by_identity?
        identity = identity_of(actor)

        identity.present? && stage.approvals.exists?(approver_identity: identity)
      end

      def identity_of(subject)
        return subject[:identity] if subject.is_a?(Hash)

        config.actor_identity&.call(subject)
      end

      def reference_of(subject)
        return subject.slice(:type, :id) if subject.is_a?(Hash)

        ChangeRequests.actor_attributes(subject).slice(:type, :id)
      end
    end
  end
end
