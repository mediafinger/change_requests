# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Stage do
  subject(:stage) { change_request.stages.create!(position: 1, name: "operational") }

  let(:change_request) do
    ChangeRequests::Request.create!(
      operation_key: "members.update_roles", service: "Members::UpdateRoles", method_name: "call",
      operation_version: "2026-09-10",
      requester_type: "User", requester_id: "1", requester_label: "Ada Lovelace"
    )
  end

  it "derives its table from the prefix" do
    expect(described_class.table_name).to eq("change_request_stages")
  end

  describe "status" do
    it "defaults to pending" do
      expect(stage).to be_pending
    end

    it "lists §5.2's four" do
      expect(described_class::STATUSES).to eq(%w(pending satisfied closed rejected))
    end

    it "rejects anything else" do
      expect(change_request.stages.build(position: 2, name: "x", status: "done")).not_to be_valid
    end

    it "scopes by each" do
      stage
      change_request.stages.create!(position: 2, name: "director", status: "closed")

      expect(described_class.pending.count).to eq(1)
      expect(described_class.closed.count).to eq(1)
    end
  end

  describe "#open?" do
    it "is true while pending" do
      expect(stage).to be_open
    end

    it "stays true while satisfied, which is when a cooldown still allows unapproval (§7.1)" do
      stage.update!(status: "satisfied")

      expect(stage).to be_open
    end

    it "is false once closed" do
      stage.update!(status: "closed")

      expect(stage).not_to be_open
    end

    it "is false once rejected" do
      stage.update!(status: "rejected")

      expect(stage).not_to be_open
    end
  end

  describe "satisfied_by" do
    it "defaults to any_quorum" do
      expect(stage).to be_any_quorum
    end

    it "reads all_quorums when set" do
      other = change_request.stages.create!(position: 2, name: "director", satisfied_by: "all_quorums")

      expect(other).to be_all_quorums
      expect(other).not_to be_any_quorum
    end

    it "rejects anything else" do
      expect(change_request.stages.build(position: 2, name: "x", satisfied_by: "either")).not_to be_valid
    end
  end

  describe "position" do
    it "must be at least one" do
      expect(change_request.stages.build(position: 0, name: "x")).not_to be_valid
    end

    it "is unique per request" do
      stage

      expect(change_request.stages.build(position: 1, name: "other")).not_to be_valid
    end

    it "may repeat across requests" do
      stage
      other_request = change_request.dup.tap(&:save!)

      expect(other_request.stages.build(position: 1, name: "operational")).to be_valid
    end

    # The validation is a nicety; the unique index is the enforcement.
    it "is unique per request in the database, not only in Ruby" do
      stage
      duplicate = change_request.stages.build(position: 1, name: "other")

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "name" do
    it "is required" do
      expect(change_request.stages.build(position: 2)).not_to be_valid
    end

    %w(operational director sign_off stage2).each do |valid|
      it "accepts the snake_case identifier #{valid}" do
        expect(change_request.stages.build(position: 2, name: valid)).to be_valid
      end
    end

    # Identifiers, not display text (§5.9).
    ["Operational", "sign off", "sign-off", "2nd", "signOff", ""].each do |invalid|
      it "rejects #{invalid.inspect}" do
        expect(change_request.stages.build(position: 2, name: invalid)).not_to be_valid
      end
    end

    it "is unique per request" do
      stage

      expect(change_request.stages.build(position: 2, name: "operational")).not_to be_valid
    end

    it "is unique per request in the database, not only in Ruby" do
      stage
      duplicate = change_request.stages.build(position: 2, name: "operational")

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  # §5.2: materialised from the operation at creation, and never edited afterwards.
  describe "the definition columns" do
    { position: 9, name: "renamed", satisfied_by: "all_quorums" }.each do |attribute, new_value|
      it "refuses to change #{attribute}" do
        stage.public_send(:"#{attribute}=", new_value)

        expect { stage.save! }.to raise_error(ChangeRequests::ReadonlyAttribute)
      end
    end

    it "still allows the columns that track progress" do
      stage.update!(status: "satisfied", satisfied_at: Time.current)

      expect(stage.reload).to be_satisfied
    end
  end

  describe "#label" do
    it "humanizes the identifier when nothing translates it" do
      expect(stage.label).to eq("Operational")
    end

    it "uses the translation when there is one" do
      with_translations("change_requests.stages.operational" => "Operational review")

      expect(stage.label).to eq("Operational review")
    end

    it "humanizes a multi-word identifier" do
      other = change_request.stages.create!(position: 2, name: "sign_off")

      expect(other.label).to eq("Sign off")
    end
  end

  describe "associations" do
    it "belongs to its request" do
      expect(stage.change_request).to eq(change_request)
    end

    it "orders its quorums by position" do
      second = stage.quorums.create!(position: 2, threshold: 1, name: "owners")
      first = stage.quorums.create!(position: 1, threshold: 1, name: "admin")

      expect(stage.reload.quorums.to_a).to eq([first, second])
    end
  end
end
