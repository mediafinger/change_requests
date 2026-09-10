# frozen_string_literal: true

module ChangeRequests
  # Eligibility by name: this one actor, whatever their permissions (§5.3). OR-ed with the permission
  # rows when both are present.
  #
  # Write-once, for the same reason as QuorumPermission.
  class QuorumEligibleActor < Record
    include Concerns::Immutable

    belongs_to :quorum, class_name: "ChangeRequests::Quorum",
                        foreign_key: :change_request_quorum_id,
                        inverse_of: :eligible_actors

    # `actor_id` is a string: a User with a uuid key and an Admin with a bigint key share the column.
    validates :actor_id, presence: true

    # M1a-9 moves this to Concerns::ActorColumns.
    validates :actor_type, presence: true,
                           inclusion: { in: ->(_) { ChangeRequests.config.actor_types.keys } }
  end
end
