# frozen_string_literal: true

module ChangeRequests
  module Guards
    # May this actor leave a note (§7.2)?
    #
    # The requester, or any eligible approver - eligible for a quorum on *any* stage, like Cancel.
    # Beyond that it refuses nothing: every final status, and a request whose operation is no longer
    # declared, both stay open to comment. A comment writes no request column, so the terminal-state
    # guard is never in its way, and post-mortem notes on a finished request are the point of an
    # audit trail (§5.5).
    #
    # This is the one guard exempt from the undeclared-operation refusal (§5.11, I8): a request
    # stranded by a removed declaration is exactly the one somebody needs to leave a note on.
    class Comment < Base
      refuses_with NotAuthorized
      exempt_from_undeclared_operation!

      def refusal
        return :not_permitted unless requester? || eligible_approver?

        nil
      end

      private

      def requester?
        same_person?(request.requester, actor)
      end
    end
  end
end
