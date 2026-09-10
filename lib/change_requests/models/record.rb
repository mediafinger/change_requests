# frozen_string_literal: true

module ChangeRequests
  # The abstract base every one of the gem's nine tables inherits from (§2).
  #
  # It references no host constant - no `ApplicationRecord`, no `belongs_to` to a host model, no
  # `Rails.` anything - because the domain core has to load against a bare ActiveRecord connection
  # with Rails undefined (§1, §15.5). Inheriting from `ActiveRecord::Base` directly is what makes
  # that true; a host's `ApplicationRecord` may carry anything at all.
  #
  # **Table names are derived, never written.** `ChangeRequests.table_name_prefix` is
  # `"change_request_"` (§2), so `Stage` finds `change_request_stages` and `QuorumPermission` finds
  # `change_request_quorum_permissions` without a line of configuration. `Request` is the single
  # exception and sets its name explicitly, because it would otherwise derive
  # `change_request_requests` rather than §4's `change_requests`.
  #
  # A model that sets `self.table_name` is therefore either `Request` or a mistake, and
  # `spec/change_requests/record_spec.rb` says so.
  class Record < ::ActiveRecord::Base
    self.abstract_class = true
  end
end
