# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Commands::Cancel do
  subject(:cancel) do
    described_class.call(request: change_request, actor: actor, reason: "No longer needed")
  end

  let(:actor) { Admin.create!(name: "Ada", roles: %w(member_admin)) }
  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "Members::UpdateRoles"
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
    end
  end

  describe "what it does" do
    it "sets the request canceled, which is final" do
      cancel

      expect(change_request.reload.status).to eq("canceled")
      expect(change_request).to be_final
    end

    it "leaves the request untouchable afterwards (§5.8)" do
      cancel

      expect { change_request.reload.update!(status: "pending") }
        .to raise_error(ChangeRequests::AlreadyFinalized)
    end

    it "leaves the stages and the approvals as they were" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: actor)

      described_class.call(request: change_request.reload, actor: requester, reason: "Never mind")

      expect(change_request.reload.approvals.count).to eq(1)
      expect(change_request.stages.sole.status).to eq("pending")
    end

    it "cancels an approved request that has not executed" do
      change_request.update!(status: "approved")

      cancel

      expect(change_request.reload.status).to eq("canceled")
    end

    it "returns the request" do
      expect(cancel).to eq(change_request)
    end
  end

  describe "the canceled event (§5.5)" do
    subject(:event) do
      cancel

      change_request.events.find_by(kind: "canceled")
    end

    it "emits exactly one" do
      cancel

      expect(change_request.events.where(kind: "canceled").count).to eq(1)
    end

    it "carries the reason as the body (Q9)" do
      expect(event.body).to eq("No longer needed")
    end

    it "attributes it to whoever cancelled" do
      expect(event.actor).to eq(type: "Admin", id: actor.id.to_s, label: "Ada (admin)")
    end

    # Recorded before the status changes, so the trail says what was called off rather than what it
    # ended up as - which is `canceled` for every one of these rows.
    it "records the status the request was cancelled out of" do
      change_request.update!(status: "approved")

      expect(event.metadata).to eq("status" => "approved")
    end

    it "records pending for a request cancelled before any decision" do
      expect(event.metadata).to eq("status" => "pending")
    end
  end

  describe "the mandatory reason (Q9)" do
    it "raises NotCancelable(:reason_required) for a blank one" do
      expect { described_class.call(request: change_request, actor: actor, reason: " ") }
        .to raise_error(ChangeRequests::NotCancelable) { |error|
          expect(error.reason).to eq(:reason_required)
        }
    end

    it "is required at the call site, so it cannot be forgotten silently" do
      expect { described_class.call(request: change_request, actor: actor) }
        .to raise_error(ArgumentError, /reason/)
    end

    it "writes nothing when it refuses" do
      expect { described_class.call(request: change_request, actor: actor, reason: nil) }
        .to raise_error(ChangeRequests::NotCancelable)

      expect(change_request.reload.status).to eq("pending")
      expect(change_request.events.where(kind: "canceled")).to be_empty
    end

    it "reports the authorization failure first" do
      expect do
        described_class.call(request: change_request, actor: Admin.create!(name: "Sam"), reason: nil)
      end.to raise_error(ChangeRequests::NotCancelable) { |error|
        expect(error.reason).to eq(:not_permitted)
      }
    end
  end

  describe "the guard" do
    # The acceptance: a stage-three approver may cancel a stage-one request.
    it "lets an approver eligible only on a later stage cancel" do
      sign_off = change_request.stages.create!(position: 2, name: "sign_off")
      sign_off.quorums.create!(position: 1, threshold: 1).permissions.create!(permission: "director")
      director = Admin.create!(name: "Dora", roles: %w(director))

      described_class.call(request: change_request, actor: director, reason: "Superseded")

      expect(change_request.reload.status).to eq("canceled")
    end

    it "raises AlreadyFinalized for a request that is already over" do
      change_request.update!(status: "expired")

      expect { cancel }.to raise_error(ChangeRequests::AlreadyFinalized) { |error|
        expect(error.reason).to eq(:already_finalized)
      }
    end

    it "raises NotCancelable while the target is executing (§8)" do
      change_request.update!(status: "executing")

      expect { cancel }.to raise_error(ChangeRequests::NotCancelable) { |error|
        expect(error.reason).to eq(:executing)
      }
    end

    it "raises NotCancelable for an actor who is neither requester nor approver" do
      expect do
        described_class.call(request: change_request, actor: Admin.create!(name: "Sam"), reason: "No")
      end.to raise_error(ChangeRequests::NotCancelable) { |error|
        expect(error.reason).to eq(:not_permitted)
      }

      expect(change_request.reload.status).to eq("pending")
    end

    it "refuses an operation that is no longer declared (§5.11)" do
      change_request # created against a live declaration, which then disappears
      ChangeRequests.operations.clear

      expect { cancel }.to raise_error(ChangeRequests::NotCancelable) { |error|
        expect(error.reason).to eq(:operation_undeclared)
      }
    end
  end
end
