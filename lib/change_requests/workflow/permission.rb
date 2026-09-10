# frozen_string_literal: true

module ChangeRequests
  class Workflow
    # Eligibility by permission x actor type, both independently nullable (§5.3):
    #
    #   ("editor", "User")  Users holding :editor      ("editor", nil)  anyone holding :editor
    #   (nil, "Admin")      any Admin                  (nil, nil)       rejected
    Permission = Data.define(:permission, :actor_type)
  end
end
