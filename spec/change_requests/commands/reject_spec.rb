# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Commands::Reject do
  subject(:reject) { described_class.call(request: change_request, actor: actor, reason: "Wrong member") }

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
  end

  # One rejection from any eligible approver, or from the requester, rejects the whole request.
  # Rejection thresholds are deliberately not modelled (§7.1).
  describe "the default: a stop" do
    it "sets the request rejected, which is final" do
      reject

      expect(change_request.reload.status).to eq("rejected")
      expect(change_request).to be_final
    end

    it "sets the current stage rejected" do
      reject

      expect(change_request.stages.sole.reload.status).to eq("rejected")
    end

    it "stops the request on one rejection, whatever the quorum threshold said" do
      expect(change_request.stages.sole.quorums.sole.threshold).to eq(2)

      reject

      expect(change_request.reload.status).to eq("rejected")
    end

    it "leaves the request untouchable afterwards (§5.8)" do
      reject

      expect { change_request.reload.update!(status: "pending") }
        .to raise_error(ChangeRequests::AlreadyFinalized)
    end
  end

  describe "config.only_record_rejections = true" do
    before { ChangeRequests.config.only_record_rejections = true }

    it "leaves the request pending, so the workflow continues (§7.1)" do
      reject

      expect(change_request.reload.status).to eq("pending")
    end

    it "leaves the stage pending" do
      reject

      expect(change_request.stages.sole.reload.status).to eq("pending")
    end

    it "still records the decision and the event" do
      reject

      expect(change_request.reload.approvals.sole.decision).to eq("rejected")
      expect(change_request.events.where(kind: "rejected").count).to eq(1)
    end

    # The rejector has spent their decision on that stage; the unique index is the guarantee.
    it "stops the rejector approving the same stage afterwards" do
      reject

      expect { ChangeRequests::Commands::Approve.call(request: change_request.reload, actor: actor) }
        .to raise_error(ChangeRequests::NotApprovable) { |error|
          expect(error.reason).to eq(:already_decided)
        }
    end

    it "lets somebody else still approve" do
      reject
      other = Admin.create!(name: "Ben", roles: %w(member_admin))

      expect { ChangeRequests::Commands::Approve.call(request: change_request.reload, actor: other) }
        .not_to raise_error
    end
  end

  # Written in both branches, so the approvals table tells the same story whatever the flag says.
  describe "the rejection row (§5.4)" do
    subject(:decision) do
      reject

      change_request.reload.approvals.sole
    end

    it "records the decision on the current stage" do
      expect(decision).to have_attributes(decision: "rejected",
                                          change_request_stage_id: change_request.stages.sole.id)
    end

    it "snapshots the rejector, label included" do
      expect(decision.approver).to include(type: "Admin", id: actor.id.to_s, label: "Ada (admin)")
    end

    it "keeps the reason beside the decision as well as in the trail" do
      expect(decision.comment).to eq("Wrong member")
    end

    it "links no quorums - a rejection is a stop, not a count (§7.1)" do
      expect(decision.quorums).to be_empty
    end

    it "is written when the requester rejects too" do
      described_class.call(request: change_request, actor: requester, reason: "Changed my mind")

      expect(change_request.reload.approvals.sole.approver_id).to eq(requester.id.to_s)
    end
  end

  describe "the rejected event (§5.5)" do
    subject(:event) do
      reject

      change_request.events.find_by(kind: "rejected")
    end

    it "emits exactly one" do
      reject

      expect(change_request.events.where(kind: "rejected").count).to eq(1)
    end

    it "carries the reason as the body" do
      expect(event.body).to eq("Wrong member")
    end

    it "attributes it to the rejector" do
      expect(event.actor).to eq(type: "Admin", id: actor.id.to_s, label: "Ada (admin)")
    end

    # Whether the workflow continued is the first thing an audit asks, and it turns on a config
    # flag that may since have been changed.
    it "records that the rejection stopped the request" do
      expect(event.metadata).to eq("stage" => "approval", "recorded_only" => false)
    end

    it "records that it did not, under only_record_rejections" do
      ChangeRequests.config.only_record_rejections = true

      expect(event.metadata).to eq("stage" => "approval", "recorded_only" => true)
    end
  end

  describe "the mandatory reason (§7.1)" do
    it "raises NotRejectable(:reason_required) for a blank one" do
      expect { described_class.call(request: change_request, actor: actor, reason: "  ") }
        .to raise_error(ChangeRequests::NotRejectable) { |error|
          expect(error.reason).to eq(:reason_required)
        }
    end

    it "raises for nil" do
      expect { described_class.call(request: change_request, actor: actor, reason: nil) }
        .to raise_error(ChangeRequests::NotRejectable) { |error|
          expect(error.reason).to eq(:reason_required)
        }
    end

    it "is required at the call site, so it cannot be forgotten silently" do
      expect { described_class.call(request: change_request, actor: actor) }
        .to raise_error(ArgumentError, /reason/)
    end

    it "writes nothing when it refuses" do
      expect { described_class.call(request: change_request, actor: actor, reason: nil) }
        .to raise_error(ChangeRequests::NotRejectable)

      expect(change_request.reload.status).to eq("pending")
      expect(change_request.approvals).to be_empty
      expect(change_request.events.where(kind: "rejected")).to be_empty
    end

    # Someone who may not reject at all should not be told they merely forgot a sentence.
    it "reports the authorization failure first" do
      expect { described_class.call(request: change_request, actor: Admin.create!(name: "Sam"), reason: nil) }
        .to raise_error(ChangeRequests::NotRejectable) { |error|
          expect(error.reason).to eq(:not_permitted)
        }
    end
  end

  describe "the guard" do
    it "raises its refusal rather than writing anything" do
      expect do
        described_class.call(request: change_request, actor: Admin.create!(name: "Sam"), reason: "No")
      end.to raise_error(ChangeRequests::NotRejectable)

      expect(change_request.reload.status).to eq("pending")
      expect(change_request.approvals).to be_empty
    end

    it "refuses a second decision from the same actor" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: actor)

      expect { described_class.call(request: change_request.reload, actor: actor, reason: "No") }
        .to raise_error(ChangeRequests::NotRejectable) { |error|
          expect(error.reason).to eq(:already_decided)
        }
    end

    it "refuses an operation that is no longer declared (§5.11)" do
      change_request # created against a live declaration, which then disappears
      ChangeRequests.operations.clear

      expect { reject }.to raise_error(ChangeRequests::NotRejectable) { |error|
        expect(error.reason).to eq(:operation_undeclared)
      }
    end

    it "declares the conflict mapping, so a race is not a 500 (§15.3)" do
      expect(described_class.conflict_mapping)
        .to eq(error_class: ChangeRequests::NotRejectable, reason: :already_decided)
    end
  end

  it "returns the request" do
    expect(reject).to eq(change_request)
  end
end
