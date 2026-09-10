# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Quorum do
  subject(:quorum) { stage.quorums.create!(position: 1, threshold: 1, name: "owners") }

  let(:change_request) do
    ChangeRequests::Request.create!(
      operation_key: "members.update_roles", service: "Members::UpdateRoles", method_name: "call",
      operation_version: "2026-09-10",
      requester_type: "User", requester_id: "1", requester_label: "Ada Lovelace"
    )
  end

  let(:stage) { change_request.stages.create!(position: 1, name: "operational") }

  it "derives its table from the prefix" do
    expect(described_class.table_name).to eq("change_request_quorums")
  end

  # I9: there never was a `rule` column. Counting approvals is the only rule.
  it "has no rule column" do
    expect(described_class.column_names).not_to include("rule")
  end

  describe "status" do
    it "defaults to pending" do
      expect(quorum).to be_pending
    end

    it "is one of two" do
      expect(described_class::STATUSES).to eq(%w(pending satisfied))
    end

    it "rejects anything else" do
      expect(stage.quorums.build(position: 2, threshold: 1, status: "closed")).not_to be_valid
    end
  end

  describe "threshold" do
    it "must be at least one" do
      expect(stage.quorums.build(position: 2, threshold: 0)).not_to be_valid
    end

    # One integer per stage cannot express "one Admin or two Owners" - two quorums can (§5.3).
    it "differs per quorum within one stage" do
      quorum
      admin = stage.quorums.create!(position: 2, threshold: 2, name: "admin")

      expect(stage.reload.quorums.map(&:threshold)).to eq([1, 2])
      expect(admin.threshold).to eq(2)
    end
  end

  describe "permission_match" do
    it "defaults to any" do
      expect(quorum).to be_any_match
    end

    it "reads all when set" do
      other = stage.quorums.create!(position: 2, threshold: 1, permission_match: "all")

      expect(other).to be_all_match
      expect(other).not_to be_any_match
    end

    it "rejects anything else" do
      expect(stage.quorums.build(position: 2, threshold: 1, permission_match: "some")).not_to be_valid
    end
  end

  describe "position" do
    it "must be at least one" do
      expect(stage.quorums.build(position: 0, threshold: 1)).not_to be_valid
    end

    it "is unique per stage" do
      quorum

      expect(stage.quorums.build(position: 1, threshold: 1)).not_to be_valid
    end

    it "is unique per stage in the database, not only in Ruby" do
      quorum
      duplicate = stage.quorums.build(position: 1, threshold: 1)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "name" do
    it "accepts a snake_case identifier" do
      expect(stage.quorums.build(position: 2, threshold: 1, name: "risk_and_compliance")).to be_valid
    end

    it "rejects display text" do
      expect(stage.quorums.build(position: 2, threshold: 1, name: "Risk Team")).not_to be_valid
    end

    # Null for the `op.approvals` shorthand, where "which quorum" is not a meaningful question.
    it "may be absent" do
      expect(stage.quorums.build(position: 2, threshold: 1, name: nil)).to be_valid
    end

    it "is unique per stage when present" do
      quorum

      expect(stage.quorums.build(position: 2, threshold: 1, name: "owners")).not_to be_valid
    end

    it "is unique per stage in the database when present" do
      quorum
      duplicate = stage.quorums.build(position: 2, threshold: 1, name: "owners")

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The unique index is partial, so several nameless quorums coexist.
    it "allows more than one quorum with no name at all" do
      stage.quorums.create!(position: 1, threshold: 1, name: nil)

      expect { stage.quorums.create!(position: 2, threshold: 1, name: nil) }.not_to raise_error
    end
  end

  describe "the definition columns" do
    { position: 9, name: "renamed", threshold: 5, permission_match: "all" }.each do |attribute, value|
      it "refuses to change #{attribute}" do
        quorum.public_send(:"#{attribute}=", value)

        expect { quorum.save! }.to raise_error(ChangeRequests::ReadonlyAttribute)
      end
    end

    it "still allows the columns that track progress" do
      quorum.update!(status: "satisfied", satisfied_at: Time.current)

      expect(quorum.reload).to be_satisfied
    end
  end

  describe "#label" do
    it "humanizes the identifier when nothing translates it" do
      expect(quorum.label).to eq("Owners")
    end

    it "uses the translation when there is one" do
      with_translations("change_requests.quorums.owners" => "Owners of the account")

      expect(quorum.label).to eq("Owners of the account")
    end

    context "when the quorum has no name" do
      subject(:quorum) { stage.quorums.create!(position: 1, threshold: 1, name: nil) }

      it "falls back to the stage's label" do
        expect(quorum.label).to eq("Operational")
      end

      it "follows the stage's translation too" do
        with_translations("change_requests.stages.operational" => "Operational review")

        expect(quorum.label).to eq("Operational review")
      end
    end
  end

  describe "associations" do
    it "belongs to its stage" do
      expect(quorum.stage).to eq(stage)
    end

    it "reaches the request through it" do
      expect(quorum.stage.change_request).to eq(change_request)
    end
  end
end
