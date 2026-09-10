# frozen_string_literal: true

module ChangeRequests
  # Which quorums an approval counted toward, resolved at decision time (§5.3).
  #
  # It exists so counting is a GROUP BY rather than a re-evaluation of every approver against every
  # quorum, and so an approval stays counted when the approver's permissions later change.
  #
  # Write-once from Ruby. Unapprove removes these rows by deleting the approval, which cascades.
  class ApprovalQuorum < Record
    include Concerns::Immutable

    belongs_to :approval, class_name: "ChangeRequests::Approval",
                          foreign_key: :change_request_approval_id,
                          inverse_of: :approval_quorums
    belongs_to :quorum, class_name: "ChangeRequests::Quorum",
                        foreign_key: :change_request_quorum_id,
                        inverse_of: :approval_quorums

    validate :quorum_belongs_to_the_approved_stage

    private

    # An approval counts toward quorums of the stage it was given on, and no other.
    def quorum_belongs_to_the_approved_stage
      return if approval.blank? || quorum.blank?
      return if quorum.change_request_stage_id == approval.change_request_stage_id

      errors.add(:quorum, "must belong to the stage the approval was given on")
    end
  end
end
