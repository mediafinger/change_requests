# frozen_string_literal: true

module ChangeRequests
  module Commands
    # The only code that changes stage or request status as a consequence of a decision (§7.1).
    #
    # A command like the others - guard, mutate, emit - but an **internal** one: it takes no actor,
    # hosts never call it, and it is invoked only from `Approve`, `Unapprove` and `Reject`, inside
    # the lock they already hold.
    #
    # Its events carry the System sentinel, and that is deliberate: closing a stage is the gem's own
    # act, not the approver's. The approvals that caused it are already in the trail, each with its
    # own actor, so "System closed the stage" sits directly beneath the rows naming everyone who
    # approved (§19.15, Q36).
    class EvaluateWorkflow < Base
      def self.call(request:)
        new(request: request).call
      end

      def perform
        return request if stage.nil?
        return request if settle_rejection == :stopped

        satisfy_quorums
        close_stage! if satisfied?

        request
      end

      private

      # No lock of its own. The caller holds one, and re-locking would reload the request they just
      # wrote to - `with_lock` reloads under SELECT … FOR UPDATE. The error mapping in
      # Commands::Base#call still applies.
      def around_perform
        yield
      end

      def stage
        @stage ||= request.current_stage
      end

      # Step 0, before any recount: a rejection outranks any number of approvals. A stage holding one
      # is `rejected` and cannot be satisfied; a stage that was rejected and holds none any more goes
      # back to `pending`, and the approvals it already collected are still there to count (§7.1).
      #
      # At cooldown 0 - all of M1 - `Commands::Reject` writes the stage and the request rejection in
      # one lock, so a `pending` request on a rejected stage never exists through the public API.
      # M9b's window is what makes this reachable; it is correct and cheap at every cooldown value,
      # so it ships here rather than being bolted on later (Q35).
      def settle_rejection
        if stopping_rejection?
          # M9b owns rejected_at, together with CloseStageJob and the window it measures.
          stage.update!(status: "rejected") unless stage.rejected?

          return :stopped
        end

        stage.update!(status: "pending") if stage.rejected?

        :unchanged
      end

      # Under only_record_rejections a rejection stops nothing: the decision and the event are
      # recorded, the stage stays open, and everyone else's approvals still count (§7.1). Asking the
      # config here rather than skipping step 0 outright means a stage rejected before the flag was
      # turned on still reopens.
      def stopping_rejection?
        return false if config.only_record_rejections

        stage.approvals.exists?(decision: "rejected")
      end

      # Counting is only via change_request_approval_quorums, written at decision time and never
      # re-derived: a later role change must not silently un-approve a request (§5.3).
      def satisfy_quorums
        stage.quorums.each do |quorum|
          met = quorum.approval_quorums.count >= quorum.threshold

          next if met == quorum.satisfied?

          quorum.update!(status: met ? "satisfied" : "pending", satisfied_at: met ? Time.current : nil)
        end
      end

      # any_quorum: at least one. all_quorums: every one - the difference between "one Admin OR two
      # Owners" and "one Admin AND two Owners" (§5.3). M9a adds the *linking* rule that stops one
      # person closing two quorums of an all_quorums stage; this is only the counting rule.
      def satisfied?
        quorums = stage.quorums.reload

        return false if quorums.empty?

        stage.all_quorums? ? quorums.all?(&:satisfied?) : quorums.any?(&:satisfied?)
      end

      # §7.1's four writes. Cooldown is M9b, so the window is always zero here and a satisfied stage
      # closes in the same breath.
      def close_stage!
        stage.quorums.select(&:satisfied?).each do |quorum|
          emit(:quorum_satisfied, metadata: quorum_metadata(quorum))
        end

        stage.update!(status: "closed", closed_at: Time.current)
        emit(:stage_satisfied, metadata: quorum_metadata(closing_quorum))

        advance
      end

      # The quorum that closed it (§7.1). With one nameless quorum per stage there is no name to
      # give, so the key is omitted rather than emitted as null, as Commands::Approve does (§5.9).
      def quorum_metadata(quorum)
        metadata = { stage: stage.name }
        metadata[:quorum] = quorum.name if quorum&.name.present?

        metadata
      end

      def closing_quorum
        stage.quorums.select(&:satisfied?).min_by(&:position)
      end

      # The sequential advance ships now (D5): deferring it would mean rewriting this command in
      # M9a rather than extending it.
      def advance
        following = request.stages.find_by(position: stage.position + 1)

        return request.update!(status: "approved") if following.nil?

        request.update!(current_stage_position: following.position)
      end
    end
  end
end
