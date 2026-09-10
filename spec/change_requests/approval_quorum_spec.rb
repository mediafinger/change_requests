# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::ApprovalQuorum do
  subject(:link) { described_class.create!(approval: approval, quorum: quorum) }

  let(:change_request) { build_request }
  let(:stage) { build_stage(change_request) }
  let(:quorum) { build_quorum(stage) }
  let(:approval) { build_approval(stage) }

  it "derives its table from the prefix" do
    expect(described_class.table_name).to eq("change_request_approval_quorums")
  end

  describe "the pair" do
    it "links an approval to a quorum" do
      expect(link.approval).to eq(approval)
      expect(link.quorum).to eq(quorum)
    end

    it "is unique" do
      link

      expect { described_class.create!(approval: approval, quorum: quorum) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    # Under any_quorum an approval links to every quorum it matches (§7.1).
    it "allows one approval to count toward several quorums" do
      link
      second = build_quorum(stage, position: 2, name: "admin")

      expect { described_class.create!(approval: approval, quorum: second) }.not_to raise_error
    end

    it "allows several approvals to count toward one quorum" do
      link
      other = build_approval(stage, actor_id: "43")

      expect { described_class.create!(approval: other, quorum: quorum) }.not_to raise_error
    end
  end

  describe "validations" do
    it "requires an approval" do
      expect(described_class.new(quorum: quorum)).not_to be_valid
    end

    it "requires a quorum" do
      expect(described_class.new(approval: approval)).not_to be_valid
    end

    # An approval counts toward quorums of the stage it was given on, and no other.
    it "refuses a quorum from a different stage" do
      other_stage = build_stage(change_request, position: 2, name: "director")
      other_quorum = build_quorum(other_stage)

      row = described_class.new(approval: approval, quorum: other_quorum)

      expect(row).not_to be_valid
      expect(row.errors[:quorum].first).to include("must belong to the stage")
    end
  end

  # Write-once from Ruby: the link records what was true at decision time and is never re-derived,
  # so a later role change cannot silently un-approve a request (§5.3).
  describe "write-once" do
    it "refuses an update" do
      other = build_quorum(stage, position: 2, name: "admin")
      link.quorum = other

      expect { link.save! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "refuses a destroy" do
      expect { link.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    # Unapprove deletes the approval; the database removes the links (§7.1).
    it "goes when its approval does" do
      link
      approval.destroy

      expect(described_class.where(id: link.id)).to be_empty
    end

    it "goes when the request does" do
      link
      change_request.destroy

      expect(described_class.where(id: link.id)).to be_empty
    end
  end
end
