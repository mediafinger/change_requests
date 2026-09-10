# frozen_string_literal: true

module ChangeRequests
  # Eligibility by name: this one actor, whatever their permissions (§5.3). OR-ed with the permission
  # rows when both are present.
  #
  # Write-once, for the same reason as QuorumPermission.
  class QuorumEligibleActor < Record
    include Concerns::ActorColumns
    include Concerns::Immutable

    belongs_to :quorum, class_name: "ChangeRequests::Quorum",
                        foreign_key: :change_request_quorum_id,
                        inverse_of: :eligible_actors

    # No label: these rows name who *may* approve, not a decision that has been made.
    actor_reference :actor, label: false
  end
end
