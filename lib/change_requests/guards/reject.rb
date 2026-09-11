# frozen_string_literal: true

module ChangeRequests
  module Guards
    # May this actor reject this request (§7.1, §7.2)?
    #
    # An eligible approver of the current open stage, or the requester - who may always stop their
    # own request.
    #
    # It says nothing about the reason. The reason is mandatory, but a Reject button is what *opens*
    # the form that collects it, so a guard refusing without one could never let the button appear.
    # `Commands::Reject` enforces it (Q25).
    class Reject < Base
      refuses_with NotRejectable

      def refusal
        # A finished request is the same refusal whichever command met it, and Q29 maps this one
        # reason to AlreadyFinalized for every guard. `:not_pending` then means what it says:
        # open, but not open for decisions (Q48).
        return :already_finalized if request.final?
        return :not_pending unless request.pending?
        return :stage_not_current if !permitted_here? && eligible_on_another_stage?
        return :already_decided if already_decided?
        return :not_permitted unless permitted_here?

        nil
      end

      private

      def permitted_here?
        requester? || eligible_quorums.any?
      end

      # Rejection is the one decision the requester may take on their own request: stopping
      # something you asked for needs no four-eyes (§7.2).
      def requester?
        same_person?(request.requester, actor)
      end
    end
  end
end
