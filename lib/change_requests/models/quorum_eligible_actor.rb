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

    # Labelled, although nobody has decided anything yet: "1 more from Cleo or Gene" has to render from
    # the row, with no query and after the actor is gone, like every other reference (M5-3).
    actor_reference :actor
  end
end
