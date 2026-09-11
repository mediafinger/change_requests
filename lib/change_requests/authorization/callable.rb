# frozen_string_literal: true

module ChangeRequests
  module Authorization
    # Wraps the host-supplied policy of §9.2:
    #
    #   config.authorization = ->(actor:, request:, stage:, action:) {
    #     Pundit.policy!(actor, request).public_send("#{action}?")
    #   }
    #
    # `Configuration#authorization=` wraps a bare callable in this, so a host writes the lambda and
    # the gem still has one object answering `allows?`.
    #
    # The quorum is the gem's unit of eligibility; a host policy is written against the request, so
    # the request and the stage are resolved from the quorum rather than asked for again.
    class Callable
      attr_reader :policy

      def initialize(policy)
        @policy = policy
      end

      def allows?(actor:, quorum:, action: :approve)
        stage = quorum.stage

        !!policy.call(actor: actor, request: stage.change_request, stage: stage, action: action)
      end
    end
  end
end
