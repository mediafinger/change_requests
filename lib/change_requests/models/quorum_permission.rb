# frozen_string_literal: true

module ChangeRequests
  # Eligibility by permission × actor type, both independently nullable (§5.3):
  #
  #   ("User", "editor")  Users holding :editor      (NULL, "editor")  anyone holding :editor
  #   ("Admin", NULL)     any Admin                  (NULL, NULL)      rejected
  #
  # Write-once: materialised from the frozen workflow when the request is created, so editing an
  # operation's permission list never changes who may approve a request already in flight.
  class QuorumPermission < Record
    include Concerns::Immutable

    belongs_to :quorum, class_name: "ChangeRequests::Quorum",
                        foreign_key: :change_request_quorum_id,
                        inverse_of: :permissions

    # M1a-9 moves this to Concerns::ActorColumns, which every actor reference shares.
    validates :actor_type, inclusion: { in: ->(_) { ChangeRequests.config.actor_types.keys } },
                           allow_nil: true

    validate :constrains_something

    private

    # Mirrors the CHECK. A row constraining neither axis is a bug, not a wildcard.
    def constrains_something
      return if permission.present? || actor_type.present?

      errors.add(:base, "a permission row must constrain a permission, an actor type, or both")
    end
  end
end
