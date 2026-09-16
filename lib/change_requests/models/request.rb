# frozen_string_literal: true

module ChangeRequests
  # A deferred invocation: what will run, who asked, and how far through its approval workflow it is.
  #
  # The only model that names its own table - the convention would derive `change_request_requests`.
  class Request < Record
    include Concerns::ActorColumns
    include Concerns::StringEnum
    include Concerns::ReadonlyAttributes
    include Concerns::TerminalStateGuard

    self.table_name = "change_requests"

    STATUSES = %w(pending approved executing successful failed rejected canceled expired).freeze
    FINAL_STATUSES = %w(successful rejected canceled expired).freeze
    OPEN_STATUSES = (STATUSES - FINAL_STATUSES).freeze

    string_enum :status, STATUSES
    terminal_states(*FINAL_STATUSES)

    # §5.1. Creation-time facts: what the request will invoke, who asked, and the labels snapshotted
    # so the row stays readable once the actor and the payload's records are gone.
    readonly_after_create :operation_key, :operation_version, :service, :method_name,
                          :payload, :payload_labels,
                          :requester_type, :requester_id, :requester_label, :requester_identity,
                          :tenant_type, :tenant_id,
                          :max_attempts

    # No `dependent:` - the database cascades. Events and the eligibility rows include
    # Concerns::Immutable, whose before_destroy would refuse a Rails-driven delete.
    has_many :stages, -> { order(:position) },
             class_name: "ChangeRequests::Stage", inverse_of: :change_request
    has_many :approvals, class_name: "ChangeRequests::Approval", inverse_of: :change_request
    has_many :events, -> { order(:occurred_at) },
             class_name: "ChangeRequests::Event", inverse_of: :change_request
    has_many :attempts, -> { order(:number) },
             class_name: "ChangeRequests::Attempt", inverse_of: :change_request

    actor_reference :requester, identity: true
    actor_reference :executer, optional: true
    actor_reference :tenant, optional: true, registry: :tenant_types

    validates :operation_key, :operation_version, :service, :method_name, presence: true
    validates :current_stage_position, :max_attempts,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 }

    scope :open, -> { where(status: OPEN_STATUSES) }
    scope :overridden, -> { where.not(overridden_at: nil) }

    # What Maintenance.expire_stale! sweeps (§8). `expires_at` is nullable and null never expires.
    scope :expired_candidates, lambda { |now = Time.current|
      where(status: %w(pending approved)).where(expires_at: ...now)
    }

    # What Maintenance.reap_stuck_executions! sweeps (§8): claimed, and nothing ever settled the
    # attempt. Inclusive at the cutoff, as Guards::Reap is - a spec asserts the two agree.
    scope :stuck_executions, lambda { |older_than = Guards::Reap::DEFAULT_STUCK_AFTER|
      claimed = Attempt.in_flight.where(started_at: ..(Time.current - older_than))

      where(status: "executing").where(id: claimed.select(:change_request_id))
    }

    # §5.11's operation-key test, and its inverse, written from one place. `visible_to` hides
    # exactly what has no live declaration and `undeclared` sweeps exactly that, so the two must
    # never both contain a row - which an empty registry is the case that would break. Rails
    # renders `IN ()` as `1=0` and `NOT IN ()` as `1=1`, so the pair stays correct with nothing
    # declared at all: everything open is undeclared, and nothing is visible.
    scope :with_declared_operation, -> { where(operation_key: ChangeRequests.operations.keys) }
    scope :with_undeclared_operation, -> { where.not(operation_key: ChangeRequests.operations.keys) }

    # What Maintenance.cancel_undeclared! sweeps (§5.11). `executing` is excluded deliberately:
    # Guards::Cancel refuses a request mid-flight, and being undeclared does not make it
    # recallable - the reaper is what clears those.
    scope :undeclared, lambda {
      where(status: OPEN_STATUSES - %w(executing)).with_undeclared_operation
    }

    # The requests this actor raised. By `(type, id)` rather than by `requester_identity`: two
    # actor classes that are one human still raised their requests separately, and §9.4's identity
    # answers "may they approve this", which is a different question.
    scope :requested_by, lambda { |actor|
      reference = ChangeRequests.actor_attributes(actor)

      where(requester_type: reference[:type], requester_id: reference[:id])
    }

    # What an actor may see (§9.3). Two rules, in this order: a request whose operation is no
    # longer declared is **invisible to everyone** - it leaves inboxes and badges the moment the
    # declaration goes, before any cleanup runs (§5.11) - and then the host's own visibility rule
    # narrows what is left.
    #
    # The engine applies it to **show as well as index**, so a cross-tenant show is a 404 rather
    # than a 403: a 403 confirms the row exists, which is what tenant scoping is hiding.
    scope :visible_to, lambda { |actor|
      ChangeRequests.config.visible_scope.call(with_declared_operation, actor)
    }

    def current_stage
      stages.find_by(position: current_stage_position)
    end

    # The attempts rows *are* the count; there is no counter column (§19.12). `max_attempts` is
    # readonly after create and `>= 1` by CHECK, so there is no zero case to defend against.
    #
    # It answers "is there an attempt left", not "may this be executed" - Guards::Execute combines
    # it with the status, and M3a's Commands::Execute and M3b's reaper both read it.
    def retryable?
      attempts.count < max_attempts
    end
  end
end
