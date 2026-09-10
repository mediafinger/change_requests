# frozen_string_literal: true

module ChangeRequests
  class Configuration
    # M0-3 fills this in: actor type registration, tenancy, authorization, separation of duties,
    # execution, events and the UI keys, plus `validate!` (§10). It exists now so
    # `ChangeRequests.config` can be memoised from the entrypoint and is never nil.
  end
end
