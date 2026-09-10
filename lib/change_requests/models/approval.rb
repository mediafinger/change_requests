# frozen_string_literal: true

module ChangeRequests
  # One approver's decision on one stage (§5.4).
  #
  # Which quorums it counted toward is recorded in ApprovalQuorum at decision time and never
  # re-derived: a later role change must not silently un-approve a request.
  #
  # Not immutable. Unapprove deletes the row and its quorum links while the stage is still open
  # (§7.1), and the database cascades the links.
  class Approval < Record
    include Concerns::StringEnum

    DECISIONS = %w(approved rejected).freeze

    string_enum :decision, DECISIONS

    belongs_to :change_request, class_name: "ChangeRequests::Request", inverse_of: :approvals
    belongs_to :stage, class_name: "ChangeRequests::Stage",
                       foreign_key: :change_request_stage_id,
                       inverse_of: :approvals

    has_many :approval_quorums, class_name: "ChangeRequests::ApprovalQuorum",
                                foreign_key: :change_request_approval_id,
                                inverse_of: :approval
    has_many :quorums, through: :approval_quorums, source: :quorum

    validates :approver_id, :approver_label, presence: true
    validates :decided_at, presence: true

    # M1a-9 moves the actor triple to Concerns::ActorColumns.
    validates :approver_type, presence: true,
                              inclusion: { in: ->(_) { ChangeRequests.config.actor_types.keys } }

    validate :change_request_matches_stage

    private

    # change_request_id is denormalised for cheap counting and scoping, which is only safe while it
    # agrees with the stage it was taken from.
    def change_request_matches_stage
      return if stage.blank? || change_request_id == stage.change_request_id

      errors.add(:change_request_id, "must be the request the stage belongs to")
    end
  end
end
