# frozen_string_literal: true

module ChangeRequests
  module Commands
    # Leaves a note on a request, whatever state it is in (§7.2, §5.5).
    #
    #   Commands::Comment.call(request:, actor: current_user, body: "Waiting on legal")
    #
    # Writes an event and nothing else - no request column changes, so the terminal-state guard is
    # never in its way and a `successful` or `canceled` request can still be annotated.
    class Comment < Base
      def self.call(request:, actor:, body:)
        new(request: request, actor: actor, body: body).call
      end

      def perform
        Guards::Comment.new(request: request, actor: actor).check!
        refuse_without_body

        # When no live declaration exists, emit stamps the request's creation-time
        # operation_version - the only version there is to record (§5.5, §5.11).
        emit(:commented, body: body)
      end

      private

      def body
        options[:body]
      end

      # An empty note is noise in a trail that can never be cleaned up. Authorization first, as in
      # Reject and Cancel.
      def refuse_without_body
        return if body.present?

        fail NotAuthorized.new(request: request, reason: :body_required)
      end
    end
  end
end
