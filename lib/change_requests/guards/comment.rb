# frozen_string_literal: true

module ChangeRequests
  module Guards
    # May this actor leave a note (§7.2)?
    #
    # Anyone registered, on any request, in any status - and on a request whose operation is no longer
    # declared (§5.11). A comment writes no lifecycle state (§5.5), so there is nothing to protect, and
    # `visible_to` already decides who can see the request to comment on it (M5-8).
    #
    # The one thing it still refuses is an unregistered actor class, and that is the registry raising
    # UnknownActorType rather than a reason (§9.1).
    class Comment < Base
      refuses_with NotAuthorized
      exempt_from_undeclared_operation!

      def refusal
        actor_ref

        nil
      end
    end
  end
end
