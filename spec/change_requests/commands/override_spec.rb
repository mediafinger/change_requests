# frozen_string_literal: true

require "rails_helper"

module OverrideProbes
  class Roles
    class << self
      attr_accessor :applied

      def call(member_id:, **)
        self.applied = member_id
      end
    end
  end
end

RSpec.describe ChangeRequests::Commands::Override do
  subject(:override) { described_class.call(request: change_request, actor: officer, reason: reason) }

  let(:reason) { "Payment provider outage, CFO approved by phone" }
  let(:officer) { Manager.create!(id: "mgr-1", name: "Olive", roles: %w(security_officer)) }
  let(:requester) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                          requester: requester, payload: { "member_id" => "42" })
  end

  # §6.10 as written: opt in per action, then pass override: true explicitly.
  def declare(permissions: %w(security_officer), require_reason: true, override: true)
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "OverrideProbes::Roles"
      op.override(permissions: permissions, require_reason: require_reason) if override
      op.workflow { |w| w.stage :operational, permissions: %w(owner), threshold: 2 }
    end
  end

  before do
    OverrideProbes::Roles.applied = nil
    declare
  end

  describe "the break-glass path (§8.1)" do
    it "executes a request that never reached approved" do
      expect(change_request.status).to eq("pending")

      override

      expect(change_request.reload.status).to eq("successful")
      expect(OverrideProbes::Roles.applied).to eq("42")
    end

    it "stamps overridden_at, so the compliance query is one column (§6.10)" do
      override

      expect(change_request.reload.overridden_at).to be_within(5.seconds).of(Time.current)
      expect(ChangeRequests::Request.where.not(overridden_at: nil)).to include(change_request)
    end

    it "still writes the ordinary attempt and execution events" do
      override

      expect(change_request.reload.attempts.sole).to have_attributes(number: 1, outcome: "succeeded")
      expect(change_request.events.map(&:kind))
        .to include("overridden", "execution_started", "executed")
    end

    it "emits overridden before the claim it explains" do
      override
      kinds = change_request.reload.events.map(&:kind)

      expect(kinds.index("overridden")).to be < kinds.index("execution_started")
    end

    it "carries the reason as the event's body, which is who-and-why (§8.1)" do
      override

      expect(change_request.reload.events.find_by!(kind: "overridden"))
        .to have_attributes(body: reason, actor_id: "mgr-1")
    end
  end

  describe "the shortfall snapshot (§8.1)" do
    subject(:metadata) do
      override

      change_request.reload.events.find_by!(kind: "overridden").metadata
    end

    it "records how far short the request was, scoped to what was still missing" do
      expect(metadata).to eq("approvals_present" => 0, "approvals_required" => 2,
                             "incomplete_stages" => %w(operational),
                             "incomplete_quorums" => [])
    end

    it "counts the approvals that had landed" do
      ChangeRequests::Commands::Approve.call(
        request: change_request, actor: User.create!(name: "Olga", email: "o@example.com", roles: %w(owner))
      )

      expect(metadata).to include("approvals_present" => 1, "approvals_required" => 2)
    end

    context "with a named quorum" do
      before do
        ChangeRequests.operations["members.update_roles"].workflow do |w|
          w.stage :operational, satisfied_by: :all_quorums do |q|
            q.quorum :admins, permissions: %w(admin), threshold: 1
            q.quorum :owners, permissions: %w(owner), threshold: 2
          end
        end
      end

      it "names the quorums that were still open" do
        expect(metadata).to include("incomplete_quorums" => %w(admins owners),
                                    "approvals_required" => 3)
      end

      it "drops a quorum that was already satisfied, the shortfall being what is left" do
        ChangeRequests::Commands::Approve.call(
          request: change_request, actor: Admin.create!(name: "Amy", roles: %w(admin))
        )

        expect(metadata).to include("incomplete_quorums" => %w(owners),
                                    "approvals_required" => 2, "approvals_present" => 0)
      end
    end

    # §8.1: "a later approval must not be able to make an override look retrospectively
    # unnecessary". Written at claim time, and never recomputed - so approvals appearing afterwards
    # leave it exactly as it was.
    it "is unchanged by approvals that land after the claim" do
      recorded = metadata
      stage = change_request.stages.sole

      2.times do |index|
        approval = stage.approvals.create!(change_request: change_request, decision: "approved",
                                           approver_type: "User", approver_id: "late-#{index}",
                                           approver_label: "Late #{index}", decided_at: Time.current)
        stage.quorums.sole.approval_quorums.create!(approval: approval)
      end

      expect(change_request.reload.events.find_by!(kind: "overridden").metadata).to eq(recorded)
    end
  end

  describe "what it refuses" do
    def reason_for(**)
      described_class.call(request: change_request, actor: officer, **)

      nil
    rescue ChangeRequests::TransitionError => e
      e.reason
    end

    it "refuses an operation that declares no override at all" do
      declare(override: false)

      expect(reason_for(reason: reason)).to eq(:override_not_permitted)
    end

    it "refuses an actor who does not hold the declared permissions" do
      stranger = Manager.create!(id: "mgr-2", name: "Sam", roles: %w(ops))

      expect { described_class.call(request: change_request, actor: stranger, reason: reason) }
        .to raise_error(ChangeRequests::OverrideNotPermitted) { |error|
          expect(error.reason).to eq(:override_not_permitted)
        }
    end

    it "refuses a missing reason when the declaration requires one" do
      expect(reason_for(reason: nil)).to eq(:reason_required)
    end

    it "allows a missing reason when the declaration does not require one" do
      declare(require_reason: false)

      expect { described_class.call(request: change_request, actor: officer) }.not_to raise_error
      expect(change_request.reload.status).to eq("successful")
    end

    # Authorization first (Q25): someone who may not override at all is not told they merely
    # forgot a sentence.
    it "answers the permission before the reason" do
      declare(permissions: %w(nobody_holds_this))

      expect(reason_for(reason: nil)).to eq(:override_not_permitted)
    end

    it "refuses the requester unless the host says otherwise (§8.1)" do
      ChangeRequests.operations["members.update_roles"].override(permissions: [], require_reason: false)

      expect { described_class.call(request: change_request, actor: requester) }
        .to raise_error(ChangeRequests::NotExecutable) { |error|
          expect(error.reason).to eq(:requester)
        }
    end

    it "allows the requester once the host turns it on" do
      ChangeRequests.operations["members.update_roles"].override(permissions: [], require_reason: false)
      ChangeRequests.config.requester_may_override = true

      expect { described_class.call(request: change_request, actor: requester) }.not_to raise_error
    end

    # An approved request executes by the ordinary path, so recording an override for it would
    # badge a request that needed none.
    it "refuses a request that is already approved" do
      2.times do |index|
        ChangeRequests::Commands::Approve.call(
          request: change_request,
          actor: User.create!(name: "O#{index}", email: "o#{index}@example.com", roles: %w(owner))
        )
      end

      expect(reason_for(reason: reason)).to eq(:not_pending)
    end

    it "refuses a request that is already finished" do
      change_request.update!(status: "canceled")

      expect(reason_for(reason: reason)).to eq(:already_finalized)
    end

    it "refuses a request whose target is already running" do
      change_request.update!(status: "executing")

      expect(reason_for(reason: reason)).to eq(:executing)
    end

    it "leaves nothing behind when it refuses" do
      declare(override: false)

      expect { described_class.call(request: change_request, actor: officer, reason: reason) }
        .to raise_error(ChangeRequests::OverrideNotPermitted)

      expect(change_request.reload).to have_attributes(status: "pending", overridden_at: nil)
      expect(change_request.attempts).to be_empty
      expect(OverrideProbes::Roles.applied).to be_nil
    end
  end

  # The acceptance: the wrapper adds a name and nothing else (Q7).
  describe "against Execute(override: true)" do
    let(:second_request) do
      ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                            requester: requester, payload: { "member_id" => "42" })
    end

    def snapshot(request)
      row = ChangeRequests::Request.find(request.id)

      [row.attributes.except("id", "created_at", "updated_at", "executed_at", "overridden_at"),
       row.events.map { |event| [event.kind, event.body, event.metadata] },
       row.attempts.map { |attempt| attempt.attributes.slice("number", "outcome") }]
    end

    it "produces identical rows and events" do
      override
      ChangeRequests::Commands::Execute.call(request: second_request, actor: officer,
                                             override: true, reason: reason)

      expect(snapshot(second_request)).to eq(snapshot(change_request))
    end

    it "is the same command class underneath, so neither can drift from the other" do
      expect(described_class).to be < ChangeRequests::Commands::Execute
    end
  end
end
