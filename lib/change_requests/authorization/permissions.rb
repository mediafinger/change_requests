# frozen_string_literal: true

module ChangeRequests
  module Authorization
    class Permissions
      # M1b-2 fills this in: `allows?(actor:, quorum:)` resolves the actor's permissions through
      # their registered type's lambda, evaluates them against the quorum's permission rows under
      # `permission_match`, and OR-s in a named-approver match (§9.2, §5.3). It exists now so
      # `config.authorization` has its documented default from the first boot.
    end
  end
end
