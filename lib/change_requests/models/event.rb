# frozen_string_literal: true

module ChangeRequests
  # The audit trail: one immutable row per transition, comment, failure or override (§5.5).
  #
  # Self-contained by design - `operation_version` is stamped here rather than joined from the
  # request, so the table can be exported alone as a complete log.
  class Event < Record
    include Concerns::StringEnum
    include Concerns::Immutable

    KINDS = %w(
      requested approved unapproved rejected commented canceled
      quorum_satisfied stage_satisfied stage_closed overridden
      execution_started executed execution_failed
      expired reaped operation_undeclared
    ).freeze

    # Inclusion only, no CHECK: every later milestone adds kinds, and a CHECK would make each one a
    # migration in every host application (§19.16).
    string_enum :kind, KINDS

    belongs_to :change_request, class_name: "ChangeRequests::Request", inverse_of: :events

    validates :operation_version, :occurred_at, presence: true
    validates :actor_id, :actor_label, presence: true

    # M1a-9 moves the actor triple to Concerns::ActorColumns.
    validates :actor_type, presence: true, inclusion: { in: ->(_) { permitted_actor_types } }

    # What Commands::Base#emit writes for a gem-originated event. M1a-9 generalises the mapping for
    # every actor reference; this is the one the audit trail needs first.
    SYSTEM_ATTRIBUTES = {
      actor_type: SYSTEM_ACTOR[:type],
      actor_id: SYSTEM_ACTOR[:id],
      actor_label: SYSTEM_ACTOR[:label],
    }.freeze

    scope :by_system, -> { where(actor_type: SYSTEM_ACTOR[:type]) }

    def self.permitted_actor_types
      ChangeRequests.config.actor_types.keys + [SYSTEM_ACTOR[:type]]
    end

    # Expiry, the reaper and undeclared-operation cancellation have no actor. The sentinel keeps the
    # triple not-null so no presenter or export branches on nil.
    def system_actor? = actor_type == SYSTEM_ACTOR[:type]
  end
end
