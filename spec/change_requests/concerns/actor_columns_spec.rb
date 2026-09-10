# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Concerns::ActorColumns do
  let(:change_request) { build_request }

  describe "assigning an actor object" do
    it "writes the type, the id and the label as it is now" do
      admin = Admin.create!(name: "Grace")

      change_request.requester = admin

      expect(change_request.requester_type).to eq("Admin")
      expect(change_request.requester_id).to eq(admin.id.to_s)
      expect(change_request.requester_label).to eq("Grace (admin)")
    end

    it "reads the triple back" do
      admin = Admin.create!(name: "Grace")
      change_request.requester = admin

      expect(change_request.requester)
        .to eq(type: "Admin", id: admin.id.to_s, label: "Grace (admin)")
    end

    it "is nil when nothing is set" do
      expect(change_request.executer).to be_nil
    end

    it "clears the triple when assigned nil" do
      change_request.executer = Admin.create!(name: "Grace")
      change_request.executer = nil

      expect(change_request.executer_type).to be_nil
      expect(change_request.executer_label).to be_nil
    end

    # §5.7 consequence 5: the registry is the allowlist, and `actor.class.name` is only ever compared
    # against it. Nothing is constantized, so a typo cannot resolve to something unexpected.
    it "raises for a class that is not registered" do
      expect { change_request.requester = Object.new }
        .to raise_error(ChangeRequests::UnknownActorType, /Object is not a registered actor type/)
    end

    it "says how to register it" do
      expect { change_request.requester = Object.new }
        .to raise_error(/config\.actor_type "Object"/)
    end
  end

  # §5.7 consequence 1, and the reason the dummy app has three actor classes.
  describe "the three key types" do
    it "round-trip through one string column" do
      user = User.create!(name: "Ada", email: "ada@example.com")
      admin = Admin.create!(name: "Grace")
      manager = Manager.create!(id: "mgr-1", name: "Alan")

      ids = [user, admin, manager].map do |actor|
        build_request(requester: actor).reload.requester_id
      end

      expect(ids).to eq([user.id, admin.id.to_s, "mgr-1"])
      expect(ids).to all(be_a(String))
    end

    it "casts a non-string id on write, without waiting for the database" do
      admin = Admin.create!(name: "Grace")

      change_request.executer_id = admin.id

      expect(change_request.executer_id).to eq(admin.id.to_s)
    end

    it "leaves nil alone rather than casting it to an empty string" do
      change_request.executer_id = nil

      expect(change_request.executer_id).to be_nil
    end
  end

  # The point of snapshotting rather than joining: an audit trail that stops rendering because
  # someone was offboarded is not an audit trail (§5.7).
  describe "a hard-deleted actor" do
    it "leaves the label intact and readable" do
      admin = Admin.create!(name: "Grace")
      request = build_request(requester: admin)

      admin.destroy

      expect(request.reload.requester_label).to eq("Grace (admin)")
    end

    it "leaves the whole triple readable" do
      admin = Admin.create!(name: "Grace")
      request = build_request(requester: admin)
      admin_id = admin.id.to_s

      admin.destroy

      expect(request.reload.requester).to eq(type: "Admin", id: admin_id, label: "Grace (admin)")
    end

    it "does not stop the request being loaded at all" do
      admin = Admin.create!(name: "Grace")
      request = build_request(requester: admin)

      admin.destroy

      expect(ChangeRequests::Request.find(request.id)).to be_present
    end
  end

  describe "optional references" do
    it "leaves an unset one valid" do
      expect(build_request).to be_valid
    end

    it "still validates the type when one is given" do
      change_request.executer_type = "Robot"

      expect(change_request).not_to be_valid
    end
  end

  describe "tenancy" do
    it "validates against the tenant registry, not the actor one" do
      change_request.tenant_type = "Admin"

      expect(change_request).not_to be_valid
    end

    it "accepts a registered tenant" do
      organization = Organization.create!(name: "Acme")

      change_request.tenant = organization

      expect(change_request.tenant_type).to eq("Organization")
      expect(change_request.tenant_label).to eq("Acme")
    end

    it "raises for a class registered as an actor but not as a tenant" do
      expect { change_request.tenant = Admin.create!(name: "Grace") }
        .to raise_error(ChangeRequests::UnknownActorType, /not a registered tenant type/)
    end
  end

  describe "the System sentinel" do
    it "is accepted where a reference allows it" do
      event = change_request.events.build(
        **ChangeRequests::Event::SYSTEM_ATTRIBUTES,
        kind: "expired", operation_version: "2026-09-10", occurred_at: Time.current
      )

      expect(event).to be_valid
    end

    it "is refused where it does not" do
      approval = ChangeRequests::Approval.new(approver_type: "System")

      approval.valid?

      expect(approval.errors[:approver_type]).to be_present
    end
  end

  describe "references with no label column" do
    let(:stage) { build_stage(change_request) }
    let(:quorum) { build_quorum(stage) }

    it "reads a triple without one" do
      row = quorum.eligible_actors.create!(actor_type: "Admin", actor_id: "42")

      expect(row.actor).to eq(type: "Admin", id: "42")
    end

    it "assigns from an actor object without trying to write one" do
      admin = Admin.create!(name: "Grace")
      row = quorum.eligible_actors.build(actor: admin)

      expect(row).to be_valid
      expect(row.actor_id).to eq(admin.id.to_s)
    end
  end
end
