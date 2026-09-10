# frozen_string_literal: true

module ChangeRequests
  class Workflow
    # One step of the described workflow, matching the columns of change_request_stages (§5.2).
    # `name` is a snake_case declaration identifier, not display text (§5.9).
    Stage = Data.define(:name, :position, :satisfied_by, :quorums)
  end
end
