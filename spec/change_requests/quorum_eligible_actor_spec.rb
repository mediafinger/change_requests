# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::QuorumEligibleActor do
  subject(:eligible_actor) { quorum.eligible_actors.create!(actor_type: "Admin", actor_id: "42") }

  let(:change_request) do
    ChangeRequests::Request.create!(
      operation_key: "members.update_roles", service: "Members::UpdateRoles", method_name: "call",
      operation_version: "2026-09-10",
      requester_type: "User", requester_id: "1", requester_label: "Ada Lovelace"
    )
  end

  let(:stage) { change_request.stages.create!(position: 1, name: "operational") }
  let(:quorum) { stage.quorums.create!(position: 1, threshold: 2, name: "named") }

  it "derives its table from the prefix" do
    expect(described_class.table_name).to eq("change_request_quorum_eligible_actors")
  end

  describe "validations" do
    it "requires an actor type" do
      expect(quorum.eligible_actors.build(actor_type: nil, actor_id: "42")).not_to be_valid
    end

    it "requires an actor id" do
      expect(quorum.eligible_actors.build(actor_type: "Admin", actor_id: nil)).not_to be_valid
    end

    it "rejects a class that is not registered" do
      expect(quorum.eligible_actors.build(actor_type: "Robot", actor_id: "42")).not_to be_valid
    end

    it "accepts each registered class" do
      %w(User Admin Manager).each do |actor_type|
        expect(quorum.eligible_actors.build(actor_type: actor_type, actor_id: "1")).to be_valid
      end
    end
  end

  # §5.7 consequence 1: a User with a uuid key and an Admin with a bigint key share one column.
  describe "actor_id" do
    it "stores a uuid" do
      user = User.create!(name: "Ada", email: "ada@example.com")
      row = quorum.eligible_actors.create!(actor_type: "User", actor_id: user.id)

      expect(row.reload.actor_id).to eq(user.id)
    end

    it "stores a bigint as text" do
      admin = Admin.create!(name: "Grace")
      row = quorum.eligible_actors.create!(actor_type: "Admin", actor_id: admin.id.to_s)

      expect(row.reload.actor_id).to eq(admin.id.to_s)
    end

    it "stores a string key unchanged" do
      Manager.create!(id: "mgr-1", name: "Alan")
      row = quorum.eligible_actors.create!(actor_type: "Manager", actor_id: "mgr-1")

      expect(row.reload.actor_id).to eq("mgr-1")
    end
  end

  describe "the unique index" do
    it "refuses the same actor twice in one quorum" do
      eligible_actor

      expect { quorum.eligible_actors.create!(actor_type: "Admin", actor_id: "42") }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    # The type is part of the key: User#42 and Admin#42 are two different people (§5.3).
    it "treats the same id under a different class as a different actor" do
      eligible_actor

      expect { quorum.eligible_actors.create!(actor_type: "User", actor_id: "42") }.not_to raise_error
    end

    it "allows the same actor in another quorum" do
      eligible_actor
      other = stage.quorums.create!(position: 2, threshold: 1, name: "others")

      expect { other.eligible_actors.create!(actor_type: "Admin", actor_id: "42") }.not_to raise_error
    end
  end

  describe "write-once" do
    it "refuses an update" do
      eligible_actor.actor_id = "43"

      expect { eligible_actor.save! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "refuses a destroy" do
      expect { eligible_actor.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "goes when its request does" do
      eligible_actor
      change_request.destroy

      expect(described_class.where(id: eligible_actor.id)).to be_empty
    end
  end

  describe "associations" do
    it "belongs to its quorum" do
      expect(eligible_actor.quorum).to eq(quorum)
    end

    it "is reachable from the quorum" do
      eligible_actor

      expect(quorum.reload.eligible_actors.to_a).to eq([eligible_actor])
    end
  end
end
