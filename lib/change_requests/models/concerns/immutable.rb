# frozen_string_literal: true

module ChangeRequests
  module Concerns
    # Append-only rows: written once, never changed, never deleted (§5.5).
    #
    # `change_request_events` is the audit trail, and an audit trail a caller can quietly update or
    # delete a row from is not one. The eligibility and approval-quorum rows are the same shape for a
    # different reason: they are materialised from the frozen workflow when a request is created, so
    # editing a permission list in an operation must never change who may approve a request already
    # in flight (§5.3).
    #
    # Both halves matter. Blocking updates while leaving `destroy` open would be a lock on the front
    # door only. The one path that legitimately removes these rows is the request's own
    # `ON DELETE CASCADE`, which is between the database and itself.
    #
    # `ActiveRecord::ReadOnlyRecord` rather than a `ChangeRequests::Error`: this is not a refused
    # domain transition a host might rescue and explain, it is a caller doing something the model
    # does not support, and Rails already has the word for that.
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
