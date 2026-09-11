# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Commands::Unapprove do
  subject(:unapprove) { described_class.call(request: change_request.reload, actor: actor) }

  let(:actor) { Admin.create!(name: "Ada", roles: %w(member_admin)) }
  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "Members::UpdateRoles"
      op.approvals permissions: %w(member_admin), required: 2
    end

    ChangeRequests::Commands::Approve.call(request: change_request, actor: actor)
  end

  describe "what it removes" do
    it "deletes the actor's approval row" do
      expect { unapprove }.to change { change_request.reload.approvals.count }.from(1).to(0)
    end

    # ApprovalQuorum is Immutable, so `approval.quorums.destroy_all` - the obvious code - raises
    # ReadOnlyRecord. Deleting the approval is what removes the links, through the cascade (Q15).
    it "lets the database cascade take the quorum links" do
      expect { unapprove }.to change(ChangeRequests::ApprovalQuorum, :count).from(1).to(0)
    end

    it "proves the obvious code is the wrong code" do
      approval = change_request.reload.approvals.sole

      expect { approval.quorums.destroy_all }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "leaves other approvers' rows alone" do
      other = Admin.create!(name: "Ben", roles: %w(member_admin))
      ChangeRequests::Commands::Approve.call(request: change_request.reload, actor: other)

      unapprove

      expect(change_request.reload.approvals.map(&:approver_id)).to eq([other.id.to_s])
    end
  end

  # The row is working state; the event is the audit trail. Neither the approval nor the
  # unapproval is erasable, so the timeline records both (§5.5).
  describe "what it keeps" do
    it "leaves the approved event standing" do
      unapprove

      expect(change_request.events.map(&:kind)).to eq(%w(requested approved unapproved))
    end

    it "cannot delete an event even deliberately" do
      approved = change_request.events.find_by(kind: "approved")

      expect { approved.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe "the unapproved event (§5.5)" do
    subject(:event) do
      unapprove

      change_request.events.find_by(kind: "unapproved")
    end

    it "emits exactly one" do
      unapprove

      expect(change_request.events.where(kind: "unapproved").count).to eq(1)
    end

    it "attributes it to the actor who retracted" do
      expect(event.actor).to eq(type: "Admin", id: actor.id.to_s, label: "Ada (admin)")
    end

    # Without this, a request that gained and lost the same approval twice would leave two
    # indistinguishable pairs in the timeline.
    it "names the stage and what was retracted" do
      expect(event.metadata).to eq("stage" => "approval", "decision" => "approved")
    end

    it "names the quorums the decision had counted toward, while they still exist" do
      change_request.stages.sole.quorums.sole.update_columns(name: "owners")

      expect(event.metadata)
        .to eq("stage" => "approval", "decision" => "approved", "quorums" => ["owners"])
    end
  end

  # The acceptance: the unique index on (stage, approver_type, approver_id) must not strand an
  # actor who changes their mind twice.
  describe "re-approval after unapproval" do
    it "succeeds" do
      unapprove

      expect { ChangeRequests::Commands::Approve.call(request: change_request.reload, actor: actor) }
        .not_to raise_error
    end

    it "leaves one approval row and a full timeline" do
      unapprove
      ChangeRequests::Commands::Approve.call(request: change_request.reload, actor: actor)

      expect(change_request.reload.approvals.count).to eq(1)
      expect(change_request.events.map(&:kind)).to eq(%w(requested approved unapproved approved))
    end

    it "links the quorums again" do
      unapprove
      ChangeRequests::Commands::Approve.call(request: change_request.reload, actor: actor)

      expect(change_request.reload.approvals.sole.quorums.count).to eq(1)
    end
  end

  describe "the guard" do
    it "raises NotUnapprovable for a different actor, writing nothing" do
      other = Admin.create!(name: "Ben", roles: %w(member_admin))

      expect { described_class.call(request: change_request.reload, actor: other) }
        .to raise_error(ChangeRequests::NotUnapprovable) { |error|
          expect(error.reason).to eq(:not_the_approver)
        }

      expect(change_request.reload.approvals.count).to eq(1)
      expect(change_request.events.where(kind: "unapproved")).to be_empty
    end

    it "refuses an operation that is no longer declared (§5.11)" do
      change_request # created against a live declaration, which then disappears
      ChangeRequests.operations.clear

      expect { unapprove }.to raise_error(ChangeRequests::NotUnapprovable) { |error|
        expect(error.reason).to eq(:operation_undeclared)
      }
    end
  end

  # Under the default, a rejection sets the request `rejected` and :not_pending refuses. This path
  # is reachable through config.only_record_rejections, where the workflow continues (§7.1).
  describe "retracting a rejection" do
    let(:rejector) { Admin.create!(name: "Cara", roles: %w(member_admin)) }

    before do
      change_request.stages.sole.approvals.create!(
        change_request: change_request, approver: rejector,
        decision: "rejected", decided_at: Time.current
      )
    end

    it "deletes the rejection row" do
      described_class.call(request: change_request.reload, actor: rejector)

      expect(change_request.reload.approvals.map(&:approver_id)).to eq([actor.id.to_s])
    end

    it "records what was retracted, so the trail distinguishes it from an approval" do
      described_class.call(request: change_request.reload, actor: rejector)

      expect(change_request.events.find_by(kind: "unapproved").metadata)
        .to eq("stage" => "approval", "decision" => "rejected")
    end
  end

  it "returns the request" do
    expect(unapprove).to eq(change_request)
  end

  # Commands::EvaluateWorkflow is M1b-12. Until it lands nothing re-counts the stage.
  it "leaves the request pending, because evaluation is M1b-12" do
    unapprove

    expect(change_request.reload.status).to eq("pending")
  end
end
