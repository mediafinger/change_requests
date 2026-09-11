# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Commands::EvaluateWorkflow do
  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  def declare(required: 1, **)
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "Members::UpdateRoles"
      op.approvals permissions: %w(member_admin), required: required
    end
  end

  def approver(name)
    Admin.create!(name: name, roles: %w(member_admin))
  end

  def approve(request, actor)
    ChangeRequests::Commands::Approve.call(request: request.reload, actor: actor)
  end

  describe "a 1-of-1 stage" do
    before { declare(required: 1) }

    it "closes the stage and approves the request on the first approval" do
      approve(change_request, approver("Ada"))

      expect(change_request.reload.status).to eq("approved")
      expect(change_request.stages.sole).to have_attributes(status: "closed")
    end

    it "stamps closed_at" do
      approve(change_request, approver("Ada"))

      expect(change_request.stages.sole.closed_at).to be_within(5.seconds).of(Time.current)
    end

    it "marks the quorum satisfied, with its timestamp" do
      approve(change_request, approver("Ada"))

      expect(change_request.stages.sole.quorums.sole)
        .to have_attributes(status: "satisfied")
      expect(change_request.stages.sole.quorums.sole.satisfied_at).to be_present
    end
  end

  describe "a 2-of-N stage" do
    before { declare(required: 2) }

    it "waits for the second approval" do
      approve(change_request, approver("Ada"))

      expect(change_request.reload.status).to eq("pending")
      expect(change_request.stages.sole.quorums.sole.status).to eq("pending")
    end

    it "closes on the second" do
      approve(change_request, approver("Ada"))
      approve(change_request, approver("Ben"))

      expect(change_request.reload.status).to eq("approved")
    end

    # Counting is only via change_request_approval_quorums, never re-derived (§5.3).
    it "counts links, not approval rows" do
      approve(change_request, approver("Ada"))
      stage = change_request.stages.sole
      # A decision with no links - what a rejection looks like - must not count toward the quorum.
      stage.approvals.create!(change_request: change_request, approver: approver("Cara"),
                              decision: "approved", decided_at: Time.current)

      described_class.call(request: change_request.reload)

      expect(change_request.reload.status).to eq("pending")
    end

    it "keeps counting an approval after the approver loses the permission that earned it" do
      ada = approver("Ada")
      approve(change_request, ada)
      ada.update!(roles: [])

      approve(change_request, approver("Ben"))

      expect(change_request.reload.status).to eq("approved")
    end
  end

  describe "a three-stage sequential workflow (D5)" do
    before do
      declare(required: 1)
      ChangeRequests.operations["members.update_roles"].instance_variable_set(
        :@workflow,
        ChangeRequests::Workflow.new(
          [stage_description("triage", 1), stage_description("review", 2), stage_description("sign_off", 3)]
        )
      )
    end

    def stage_description(name, position)
      ChangeRequests::Workflow::Stage.new(
        name: name, position: position, satisfied_by: :any_quorum,
        quorums: [
          ChangeRequests::Workflow::Quorum.new(
            name: nil, position: 1, threshold: 1, permission_match: nil,
            permissions: [ChangeRequests::Workflow::Permission.new(permission: "member_admin",
                                                                   actor_type: nil)],
            eligible_actors: []
          ),
        ]
      )
    end

    it "advances one stage at a time" do
      approve(change_request, approver("Ada"))

      expect(change_request.reload).to have_attributes(status: "pending", current_stage_position: 2)
    end

    it "reaches approved only after the last stage closes" do
      approve(change_request, approver("Ada"))
      approve(change_request, approver("Ben"))

      expect(change_request.reload.status).to eq("pending")

      approve(change_request, approver("Cara"))

      expect(change_request.reload).to have_attributes(status: "approved", current_stage_position: 3)
    end

    it "closes each stage as it passes and leaves the later ones alone" do
      approve(change_request, approver("Ada"))

      expect(change_request.stages.map(&:status)).to eq(%w(closed pending pending))
    end

    it "refuses an approval aimed at a stage that is no longer current" do
      first = change_request.stages.first
      approve(change_request, approver("Ada"))
      only_on_the_closed_stage = approver("Dana")
      first.quorums.sole.eligible_actors.create!(actor: only_on_the_closed_stage)
      change_request.stages.second.quorums.sole.permissions.sole.update_columns(permission: "director")

      expect { approve(change_request, only_on_the_closed_stage) }
        .to raise_error(ChangeRequests::NotApprovable) { |error|
          expect(error.reason).to eq(:stage_not_current)
        }
    end
  end

  # any_quorum: at least one. all_quorums: every one - the difference between "one Admin OR two
  # Owners" and "one Admin AND two Owners" (§5.3). M9a adds the linking rule, not this one.
  describe "satisfied_by" do
    before { declare(required: 1) }

    def two_quorums(satisfied_by)
      stage = change_request.stages.sole
      stage.update_columns(satisfied_by: satisfied_by)
      stage.quorums.sole.update_columns(name: "admins")
      second = stage.quorums.create!(position: 2, name: "owners", threshold: 1)
      second.permissions.create!(permission: "owner")

      stage
    end

    it "closes an any_quorum stage when one of its quorums is met" do
      two_quorums("any_quorum")

      approve(change_request, approver("Ada"))

      expect(change_request.reload.status).to eq("approved")
    end

    it "does not close an all_quorums stage on one of two" do
      two_quorums("all_quorums")

      approve(change_request, approver("Ada"))

      expect(change_request.reload.status).to eq("pending")
      expect(change_request.stages.sole.status).to eq("pending")
    end

    it "closes an all_quorums stage once every quorum is met" do
      two_quorums("all_quorums")
      approve(change_request, approver("Ada"))

      approve(change_request, Admin.create!(name: "Otto", roles: %w(owner)))

      expect(change_request.reload.status).to eq("approved")
    end

    # Reachable only under all_quorums: under any_quorum the stage closes the instant a quorum is
    # satisfied, so there is never a satisfied quorum on an open stage to lose its threshold.
    it "returns a quorum that lost its threshold to pending, leaving the request pending" do
      stage = two_quorums("all_quorums")
      ada = approver("Ada")
      approve(change_request, ada)
      admins = stage.quorums.find_by(name: "admins")

      expect(admins.reload).to have_attributes(status: "satisfied")

      ChangeRequests::Commands::Unapprove.call(request: change_request.reload, actor: ada)

      expect(admins.reload).to have_attributes(status: "pending", satisfied_at: nil)
      expect(change_request.reload.status).to eq("pending")
    end
  end

  describe "the events it emits (§7.1)" do
    subject(:events) do
      approve(change_request, approver("Ada"))

      change_request.events.order(:occurred_at)
    end

    before { declare(required: 1) }

    it "emits one quorum_satisfied and one stage_satisfied" do
      expect(events.map(&:kind)).to eq(%w(requested approved quorum_satisfied stage_satisfied))
    end

    # Closing a stage is the gem's own act, not the approver's. The approvals that caused it are
    # already in the trail, each with its own actor (§19.15, Q36).
    it "attributes both to the System sentinel" do
      closing = events.where(kind: %w(quorum_satisfied stage_satisfied))

      expect(closing.map(&:actor).uniq).to eq([ChangeRequests::SYSTEM_ACTOR])
    end

    it "names the stage" do
      expect(events.find_by(kind: "stage_satisfied").metadata).to eq("stage" => "approval")
    end

    # §5.9: with one nameless quorum per stage there is no name to give, so the key is omitted
    # rather than emitted as null.
    it "omits the quorum key when the quorum has no name" do
      expect(events.find_by(kind: "quorum_satisfied").metadata).not_to have_key("quorum")
    end

    it "names the quorum that closed the stage when it has one" do
      change_request.stages.sole.quorums.sole.update_columns(name: "owners")
      approve(change_request, approver("Ada"))

      expect(change_request.events.find_by(kind: "stage_satisfied").metadata)
        .to eq("stage" => "approval", "quorum" => "owners")
    end

    it "emits one quorum_satisfied per quorum that met its threshold" do
      stage = change_request.stages.sole
      stage.update_columns(satisfied_by: "all_quorums")
      stage.quorums.sole.update_columns(name: "admins")
      stage.quorums.create!(position: 2, name: "owners", threshold: 1)
           .permissions.create!(permission: "owner")

      approve(change_request, approver("Ada"))
      approve(change_request, Admin.create!(name: "Otto", roles: %w(owner)))

      expect(change_request.events.where(kind: "quorum_satisfied").map { |e| e.metadata["quorum"] })
        .to contain_exactly("admins", "owners")
    end
  end

  describe "rejection" do
    before { declare(required: 2) }

    it "does not advance past a stage a rejection stopped" do
      ChangeRequests::Commands::Reject.call(request: change_request, actor: approver("Ada"),
                                            reason: "Wrong member")

      expect(change_request.reload.status).to eq("rejected")
      expect(change_request.stages.sole.status).to eq("rejected")
    end

    # The workflow continues, so everyone else's approvals still count (§7.1).
    describe "under only_record_rejections" do
      before { ChangeRequests.config.only_record_rejections = true }

      it "leaves the stage open" do
        ChangeRequests::Commands::Reject.call(request: change_request, actor: approver("Ada"),
                                              reason: "Noted")

        expect(change_request.reload.status).to eq("pending")
        expect(change_request.stages.sole.status).to eq("pending")
      end

      it "advances past a rejected-but-recorded decision once the threshold is met" do
        ChangeRequests::Commands::Reject.call(request: change_request, actor: approver("Ada"),
                                              reason: "Noted")
        approve(change_request, approver("Ben"))
        approve(change_request, approver("Cara"))

        expect(change_request.reload.status).to eq("approved")
      end

      it "does not count the rejection toward the quorum" do
        ChangeRequests::Commands::Reject.call(request: change_request, actor: approver("Ada"),
                                              reason: "Noted")
        approve(change_request, approver("Ben"))

        expect(change_request.reload.status).to eq("pending")
      end
    end

    # Step 0 of §7.1. At cooldown 0 - all of M1 - Commands::Reject writes the stage and the request
    # rejection in one lock, so a `pending` request on a `rejected` stage never exists through the
    # public API. These examples write the stage status directly and are saying so out loud: the
    # rule is correct at every cooldown value and M9b's window is what makes it reachable (Q35).
    describe "step 0, unreachable through the commands until M9b" do
      it "refuses to satisfy a stage that holds a standing rejection" do
        stage = change_request.stages.sole
        stage.approvals.create!(change_request: change_request, approver: approver("Ada"),
                                decision: "rejected", decided_at: Time.current)
        approve(change_request, approver("Ben"))
        approve(change_request, approver("Cara"))

        expect(change_request.reload.status).to eq("pending")
        expect(stage.reload.status).to eq("rejected")
      end

      # Withdrawing the rejection is Unapprove's job, but its guard refuses a stage that is not
      # `pending` - correctly, in M1, where nothing reopens a stopped stage. M9b's window is what
      # lets Unapprove reach this; here the row goes directly and the evaluation is asked.
      it "returns a rejected stage to pending when its last rejection is withdrawn" do
        stage = change_request.stages.sole
        rejection = stage.approvals.create!(change_request: change_request, approver: approver("Ada"),
                                            decision: "rejected", decided_at: Time.current)
        described_class.call(request: change_request.reload)

        expect(stage.reload.status).to eq("rejected")

        rejection.destroy!
        described_class.call(request: change_request.reload)

        expect(stage.reload.status).to eq("pending")
      end

      it "keeps the stage rejected while any rejection still stands" do
        stage = change_request.stages.sole
        rejections = [approver("Ada"), approver("Ben")].map do |rejector|
          stage.approvals.create!(change_request: change_request, approver: rejector,
                                  decision: "rejected", decided_at: Time.current)
        end
        described_class.call(request: change_request.reload)

        rejections.first.destroy!
        described_class.call(request: change_request.reload)

        expect(stage.reload.status).to eq("rejected")
      end

      it "counts the approvals it collected all along, once the rejection goes" do
        stage = change_request.stages.sole
        rejection = stage.approvals.create!(change_request: change_request, approver: approver("Ada"),
                                            decision: "rejected", decided_at: Time.current)
        described_class.call(request: change_request.reload)
        stage.update_columns(status: "pending") # so Guards::Approve lets the two through
        approve(change_request, approver("Ben"))
        approve(change_request, approver("Cara"))
        stage.update_columns(status: "rejected")

        rejection.destroy!
        described_class.call(request: change_request.reload)

        expect(change_request.reload.status).to eq("approved")
      end

      # M9b owns rejected_at, together with CloseStageJob and the window it measures.
      it "writes no rejected_at, which is M9b's" do
        stage = change_request.stages.sole
        stage.approvals.create!(change_request: change_request, approver: approver("Ada"),
                                decision: "rejected", decided_at: Time.current)

        described_class.call(request: change_request.reload)

        expect(stage.reload.rejected_at).to be_nil
      end
    end
  end

  describe "its shape as a command" do
    before { declare(required: 1) }

    it "takes no actor - closing a stage is nobody's decision (§7.1)" do
      expect(described_class.method(:call).parameters).to eq([%i(keyreq request)])
    end

    it "returns the request" do
      expect(described_class.call(request: change_request)).to eq(change_request)
    end

    it "does nothing to a request whose stages are all behind it" do
      approve(change_request, approver("Ada"))

      expect { described_class.call(request: change_request.reload) }
        .not_to(change { change_request.reload.status })
    end

    # It runs inside the caller's lock; re-locking would reload the request they just wrote to, and
    # `with_lock` refuses a record carrying unsaved changes.
    it "opens no lock of its own" do
      allow(change_request).to receive(:with_lock).and_call_original

      described_class.call(request: change_request)

      expect(change_request).not_to have_received(:with_lock)
    end
  end
end
