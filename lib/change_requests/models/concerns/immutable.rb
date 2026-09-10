# frozen_string_literal: true

module ChangeRequests
  module Concerns
    # Append-only: blocks update *and* destroy. Used by events (§5.5) and by the eligibility rows,
    # which are materialised from the frozen workflow and must not change for an in-flight request.
    #
    # Raises ActiveRecord::ReadOnlyRecord, not a ChangeRequests::Error: unsupported operation, not a
    # refused domain transition. ON DELETE CASCADE bypasses it, by design.
    module Immutable
      extend ActiveSupport::Concern

      included do
        before_update { fail ActiveRecord::ReadOnlyRecord, self.class.immutable_message("updated") }
        before_destroy { fail ActiveRecord::ReadOnlyRecord, self.class.immutable_message("deleted") }
      end

      class_methods do
        def immutable_message(verb)
          "#{name} rows are append-only and cannot be #{verb} (§5.5)"
        end
      end
    end
  end
end
