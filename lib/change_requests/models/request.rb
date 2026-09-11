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

    def current_stage
      stages.find_by(position: current_stage_position)
    end
  end
end
