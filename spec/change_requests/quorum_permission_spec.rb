# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::QuorumPermission do
  subject(:permission) { quorum.permissions.create!(permission: "owner") }

  let(:change_request) do
    ChangeRequests::Request.create!(
      operation_key: "members.update_roles", service: "Members::UpdateRoles", method_name: "call",
      operation_version: "2026-09-10",
      requester_type: "User", requester_id: "1", requester_label: "Ada Lovelace"
    )
  end

  let(:stage) { change_request.stages.create!(position: 1, name: "operational") }
  let(:quorum) { stage.quorums.create!(position: 1, threshold: 1, name: "owners") }

  it "derives its table from the prefix" do
    expect(described_class.table_name).to eq("change_request_quorum_permissions")
  end

  # §5.3's 2×2. Both axes are independently nullable, and NULL means "any" on that axis.
  describe "the eligibility matrix" do
    [
      ["User",  "editor", true,  "Users holding the permission"],
      [nil,     "editor", true,  "anyone holding the permission, whatever their class"],
      ["Admin", nil,      true,  "any Admin, whatever their permissions"],
      [nil,     nil,      false, "a row that constrains nothing"],
    ].each do |actor_type, permission_name, valid, description|
      it "#{valid ? "accepts" : "rejects"} #{description}" do
        row = quorum.permissions.build(actor_type: actor_type, permission: permission_name)

        expect(row.valid?).to be(valid)
      end
    end

    it "explains why the doubly-null row was refused" do
      row = quorum.permissions.build(actor_type: nil, permission: nil)
      row.valid?

      expect(row.errors[:base].first).to include("must constrain")
    end

    # The validation is a nicety; the CHECK constraint is the enforcement.
    it "refuses the doubly-null row at the database too" do
      row = quorum.permissions.build(actor_type: nil, permission: nil)

      expect { row.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe "actor_type" do
    it "accepts a registered class" do
      expect(quorum.permissions.build(actor_type: "Manager")).to be_valid
    end

    # §5.7 consequence 5: the registered types are an allowlist, checked before the string is ever
    # constantized, so a typo fails on write rather than at render time.
    it "rejects one that is not registered" do
      expect(quorum.permissions.build(actor_type: "Robot")).not_to be_valid
    end

    it "rejects the System sentinel, which is never eligible to approve" do
      expect(quorum.permissions.build(actor_type: "System")).not_to be_valid
    end

    it "follows the configured allowlist rather than a hard-coded one" do
      expect(ChangeRequests.config.actor_types.keys).to include("User", "Admin", "Manager")
    end
  end

  # Issue I3, from the model's side: PostgreSQL treats every NULL as distinct unless the index says
  # otherwise, so without NULLS NOT DISTINCT the "any permission, Admin" row inserts twice.
  describe "the unique index" do
    it "refuses a duplicate (quorum, NULL, Admin) row" do
      quorum.permissions.create!(permission: nil, actor_type: "Admin")

      expect { quorum.permissions.create!(permission: nil, actor_type: "Admin") }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "refuses a duplicate (quorum, editor, NULL) row" do
      quorum.permissions.create!(permission: "editor", actor_type: nil)

      expect { quorum.permissions.create!(permission: "editor", actor_type: nil) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same pair under a different quorum" do
      quorum.permissions.create!(permission: nil, actor_type: "Admin")
      other = stage.quorums.create!(position: 2, threshold: 1, name: "admins")

      expect { other.permissions.create!(permission: nil, actor_type: "Admin") }.not_to raise_error
    end
  end

  # Materialised from the frozen workflow, so editing an operation's permission list never changes
  # who may approve a request already in flight.
  describe "write-once" do
    it "refuses an update" do
      permission.permission = "editor"

      expect { permission.save! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "refuses a destroy" do
      expect { permission.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    # The database cascade is the one path that removes these rows.
    it "goes when its request does" do
      permission
      change_request.destroy

      expect(described_class.where(id: permission.id)).to be_empty
    end
  end

  describe "associations" do
    it "belongs to its quorum" do
      expect(permission.quorum).to eq(quorum)
    end

    it "is reachable from the quorum" do
      permission

      expect(quorum.reload.permissions.to_a).to eq([permission])
    end
  end
end
