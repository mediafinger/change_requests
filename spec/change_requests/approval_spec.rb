# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Approval do
  subject(:approval) { build_approval(stage) }

  let(:change_request) { build_request }
  let(:stage) { build_stage(change_request) }

  it "derives its table from the prefix" do
    expect(described_class.table_name).to eq("change_request_approvals")
  end

  describe "decision" do
    it "is approved or rejected" do
      expect(described_class::DECISIONS).to eq(%w(approved rejected))
    end

    it "answers a predicate" do
      expect(approval).to be_approved
      expect(approval).not_to be_rejected
    end

    it "rejects anything else" do
      expect(stage.approvals.build(decision: "maybe")).not_to be_valid
    end

    it "scopes by each" do
      approval
      build_approval(stage, actor_id: "43", decision: "rejected", comment: "Wrong member")

      expect(described_class.approved.count).to eq(1)
      expect(described_class.rejected.count).to eq(1)
    end
  end

  describe "validations" do
    it "requires decided_at" do
      expect(stage.approvals.build(**valid_attributes, decided_at: nil)).not_to be_valid
    end

    it "requires the approver triple" do
      %i(approver_type approver_id approver_label).each do |attribute|
        expect(stage.approvals.build(**valid_attributes, attribute => nil)).not_to be_valid
      end
    end

    it "rejects an approver class that is not registered" do
      expect(stage.approvals.build(**valid_attributes, approver_type: "Robot")).not_to be_valid
    end

    it "leaves approver_identity optional, since only some hosts have one (§9.4)" do
      expect(approval.approver_identity).to be_nil
    end

    it "stores approver_identity when a host supplies one" do
      other = build_approval(stage, actor_id: "43", approver_identity: "person-7")

      expect(other.reload.approver_identity).to eq("person-7")
    end

    it "leaves the comment optional" do
      expect(approval.comment).to be_nil
    end
  end

  # change_request_id is denormalised for cheap counting and scoping, which is only safe while it
  # agrees with the stage it was taken from.
  describe "the denormalised request id" do
    it "is set to the stage's request" do
      expect(approval.change_request_id).to eq(change_request.id)
    end

    it "refuses to disagree with the stage" do
      other_request = build_request

      row = stage.approvals.build(**valid_attributes, change_request: other_request)

      expect(row).not_to be_valid
      expect(row.errors[:change_request_id].first).to include("must be the request")
    end
  end

  # §5.4: the database, not application code, enforces one decision per approver per stage.
  describe "one decision per approver per stage" do
    it "refuses a second decision from the same actor" do
      approval

      expect { build_approval(stage) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "refuses it even with validations skipped, because the index is the enforcement" do
      approval
      duplicate = stage.approvals.build(**valid_attributes)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The type is part of the key: User#7 and Admin#7 are two different people.
    it "treats the same id under a different class as a different person" do
      build_approval(stage, actor_type: "Admin", actor_id: "7")

      expect { build_approval(stage, actor_type: "User", actor_id: "7") }.not_to raise_error
    end

    it "allows the same actor to decide a later stage" do
      approval
      second_stage = build_stage(change_request, position: 2, name: "director")

      expect { build_approval(second_stage) }.not_to raise_error
    end
  end

  # Unapprove deletes the row while the stage is still open (§7.1), so this one is not immutable.
  describe "deletion" do
    it "can be destroyed" do
      approval.destroy

      expect(described_class.where(id: approval.id)).to be_empty
    end

    it "takes its quorum links with it, through the database cascade" do
      quorum = build_quorum(stage)
      approval.quorums = [quorum]

      approval.destroy

      expect(ChangeRequests::ApprovalQuorum.where(change_request_approval_id: approval.id)).to be_empty
    end
  end

  describe "quorum links" do
    it "records which quorums the decision counted toward" do
      admin = build_quorum(stage, position: 1, name: "admin")
      owners = build_quorum(stage, position: 2, name: "owners")

      approval.quorums = [admin, owners]

      expect(approval.reload.quorums).to contain_exactly(admin, owners)
    end

    it "is reachable from the quorum's side, which is how counting works" do
      quorum = build_quorum(stage)
      approval.quorums = [quorum]

      expect(quorum.reload.approvals).to eq([approval])
    end
  end

  describe "associations" do
    it "belongs to its stage" do
      expect(approval.stage).to eq(stage)
    end

    it "belongs to its request" do
      expect(approval.change_request).to eq(change_request)
    end

    it "is reachable from the request" do
      approval

      expect(change_request.reload.approvals.to_a).to eq([approval])
    end
  end

  def valid_attributes
    {
      change_request: change_request,
      approver_type: "Admin",
      approver_id: "42",
      approver_label: "Admin 42",
      decision: "approved",
      decided_at: Time.current,
    }
  end
end
