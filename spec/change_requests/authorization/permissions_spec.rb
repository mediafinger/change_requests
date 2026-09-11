# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Authorization::Permissions do
  subject(:authorization) { described_class.new }

  def eligible?(actor:, quorum:)
    authorization.allows?(actor: actor, quorum: quorum)
  end

  it_behaves_like "the eligibility predicate"

  describe "resolving the actor's permissions" do
    let(:change_request) { build_request }
    let(:stage) { build_stage(change_request) }
    let(:quorum) { build_quorum(stage) }

    # User and Admin derive their permissions completely differently and are still compared against
    # one stage definition (§9.2).
    it "goes through the actor type's own lambda, not through a method on the actor" do
      admin = Admin.create!(name: "Ada")
      quorum.permissions.create!(permission: "admin", actor_type: nil)

      expect(eligible?(actor: admin, quorum: quorum.reload)).to be(true)
    end

    it "treats a type with no permissions lambda as holding none" do
      ChangeRequests.config.actor_type("Admin") { |type| type.permissions = nil }
      quorum.permissions.create!(permission: "admin", actor_type: nil)

      expect(eligible?(actor: Admin.create!(name: "Ada"), quorum: quorum.reload)).to be(false)
    end

    it "compares permissions as strings, so a lambda returning symbols still matches" do
      ChangeRequests.config.actor_type("Admin") { |type| type.permissions = ->(_a) { [:auditor] } }
      quorum.permissions.create!(permission: "auditor", actor_type: nil)

      expect(eligible?(actor: Admin.create!(name: "Ada"), quorum: quorum.reload)).to be(true)
    end

    it "reads the actor type verbatim, so an STI subclass is not collapsed to its base (§9.1)" do
      quorum.permissions.create!(permission: nil, actor_type: "Manager")

      expect(eligible?(actor: Manager.create!(id: "m-1", name: "Mel"), quorum: quorum.reload)).to be(true)
    end
  end

  describe "#allows? signature" do
    let(:quorum) { build_quorum(build_stage(build_request)) }

    it "accepts an action, which the pluggable callable needs and this policy does not" do
      quorum.permissions.create!(permission: nil, actor_type: "Admin")

      expect(authorization.allows?(actor: Admin.create!(name: "Ada"), quorum: quorum.reload,
                                   action: :approve)).to be(true)
    end
  end
end
