# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Guards::Approve do
  subject(:guard) { described_class.new(request: change_request, actor: actor) }

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

  it_behaves_like "a change request guard"

  it "refuses with its own error (§7)" do
    expect(described_class.error_class).to eq(ChangeRequests::NotApprovable)
  end

  describe "the happy path" do
    it "allows an eligible approver who is not the requester" do
      expect(guard).to be_allowed
      expect(guard.reason).to be_nil
    end
  end

  # Order decides which reason a user sees, so it is asserted, not assumed (§7).
  describe "the refusal order" do
    it "prefers :already_finalized over everything else, for a request that is over" do
      change_request.update!(status: "canceled")

      expect(guard.reason).to eq(:already_finalized)
    end

    it "prefers :not_pending over everything a still-open request could say" do
      change_request.update!(status: "approved")

      expect(guard.reason).to eq(:not_pending)
    end

    it "prefers :requester over :not_permitted" do
      guard = described_class.new(request: change_request, actor: requester)

      expect(guard.reason).to eq(:requester)
    end

    it "prefers :stage_not_current over :already_decided" do
      later_stage_actor = Admin.create!(name: "Dora", roles: %w(director))
      sign_off = change_request.stages.create!(position: 2, name: "sign_off")
      quorum = sign_off.quorums.create!(position: 1, threshold: 1)
      quorum.permissions.create!(permission: "director")

      guard = described_class.new(request: change_request, actor: later_stage_actor)

      expect(guard.reason).to eq(:stage_not_current)
    end
  end

  describe ":not_pending" do
    %w(approved executing failed).each do |status|
      it "refuses a request that is #{status}" do
        change_request.update!(status: status)

        expect(guard.reason).to eq(:not_pending)
      end
    end

    ChangeRequests::Request::FINAL_STATUSES.each do |status|
      it "refuses a request that is already #{status} with the shared reason (Q48)" do
        change_request.update!(status: status)

        expect(guard.reason).to eq(:already_finalized)
      end
    end
  end

  # Never configurable. There is no config.requester_may_approve to read, in any form (I5, §19.17).
  describe ":requester" do
    it "refuses the requester approving their own request" do
      guard = described_class.new(request: change_request, actor: requester)

      expect(guard.reason).to eq(:requester)
    end

    it "raises NotApprovable carrying the reason" do
      guard = described_class.new(request: change_request, actor: requester)

      expect { guard.check! }.to raise_error(ChangeRequests::NotApprovable) { |error|
        expect(error.reason).to eq(:requester)
      }
    end

    it "consults no configuration at all" do
      expect(ChangeRequests.config).not_to respond_to(:requester_may_approve)
      expect(ChangeRequests.config).not_to respond_to(:requester_may_approve=)
    end

    it "separates two different people of the same class" do
      other = User.create!(name: "Rhea", email: "rhea@example.com")
      change_request.stages.sole.quorums.sole.eligible_actors.create!(actor: other)

      expect(described_class.new(request: change_request, actor: other)).to be_allowed
    end

    # Without config.actor_identity, (type, id) is airtight within one actor class and blind across
    # them. The requester_identity snapshot is what closes that (§9.4).
    it "sees through two actor classes when config.actor_identity says they are one person" do
      ChangeRequests.config.actor_identity = ->(person) { person.name }
      change_request = ChangeRequests::Commands::Create.call(
        operation_key: "members.update_roles", requester: requester
      )
      twin = Admin.create!(name: "Rita", roles: %w(member_admin))

      expect(described_class.new(request: change_request, actor: twin).reason).to eq(:requester)
    end

    it "still separates two genuinely different people under an identity lambda" do
      ChangeRequests.config.actor_identity = ->(person) { person.name }
      change_request = ChangeRequests::Commands::Create.call(
        operation_key: "members.update_roles", requester: requester
      )

      expect(described_class.new(request: change_request, actor: actor)).to be_allowed
    end
  end

  # §6.9: a stage-three director may not approve a request sitting in stage one. "Not your turn
  # yet" is a different answer from "you cannot approve this at all".
  describe ":stage_not_current" do
    let(:director) { Admin.create!(name: "Dora", roles: %w(director)) }

    before do
      sign_off = change_request.stages.create!(position: 2, name: "sign_off")
      quorum = sign_off.quorums.create!(position: 1, threshold: 1)
      quorum.permissions.create!(permission: "director")
    end

    it "refuses an actor eligible only on a later stage" do
      expect(described_class.new(request: change_request, actor: director).reason)
        .to eq(:stage_not_current)
    end

    it "allows them once the request reaches their stage" do
      change_request.update!(current_stage_position: 2)

      expect(described_class.new(request: change_request, actor: director)).to be_allowed
    end

    it "says :not_permitted, not :stage_not_current, for an actor eligible nowhere" do
      stranger = Admin.create!(name: "Sam")

      expect(described_class.new(request: change_request, actor: stranger).reason)
        .to eq(:not_permitted)
    end
  end

  describe ":already_decided" do
    def approve_as(approver)
      ChangeRequests::Commands::Approve.call(request: change_request.reload, actor: approver)
    end

    it "refuses a second decision on the same stage by the same actor" do
      approve_as(actor)

      expect(described_class.new(request: change_request.reload, actor: actor).reason)
        .to eq(:already_decided)
    end

    it "allows a different eligible actor" do
      approve_as(actor)
      other = Admin.create!(name: "Ben", roles: %w(member_admin))

      expect(described_class.new(request: change_request.reload, actor: other)).to be_allowed
    end

    # §9.4: the identity is used in place of (type, id) when counting distinct approvers, so one
    # human cannot decide the same stage twice through two registered classes.
    it "refuses the same person acting as a second actor class when actor_identity is set" do
      ChangeRequests.config.actor_identity = ->(person) { person.name }
      approve_as(actor)
      twin = User.create!(name: "Ada", email: "ada@example.com", roles: %w(member_admin))

      expect(described_class.new(request: change_request.reload, actor: twin).reason)
        .to eq(:already_decided)
    end

    it "does not confuse two people who merely share a class" do
      ChangeRequests.config.actor_identity = ->(person) { person.name }
      approve_as(actor)
      other = Admin.create!(name: "Ben", roles: %w(member_admin))

      expect(described_class.new(request: change_request.reload, actor: other)).to be_allowed
    end

    it "looks only at the stage being decided" do
      change_request.stages.create!(position: 2, name: "sign_off")
      approve_as(actor)
      change_request.update!(current_stage_position: 2)

      expect(described_class.new(request: change_request.reload, actor: actor).reason)
        .not_to eq(:already_decided)
    end
  end

  describe ":not_permitted" do
    it "refuses an actor who satisfies no quorum of the current stage" do
      stranger = Admin.create!(name: "Sam")

      expect(described_class.new(request: change_request, actor: stranger).reason)
        .to eq(:not_permitted)
    end

    it "refuses an actor class that may not approve (§9.1)" do
      ChangeRequests.config.actor_types.fetch("Admin").may_approve = false

      expect(guard.reason).to eq(:not_permitted)
    end
  end

  describe "#eligible_quorums" do
    it "is the quorums of the current stage this actor qualifies for" do
      expect(guard.eligible_quorums).to eq([change_request.stages.sole.quorums.sole])
    end

    it "is empty for an actor who qualifies for none" do
      guard = described_class.new(request: change_request, actor: Admin.create!(name: "Sam"))

      expect(guard.eligible_quorums).to be_empty
    end

    it "skips a quorum that is already satisfied" do
      change_request.stages.sole.quorums.sole.update!(status: "satisfied")

      expect(guard.eligible_quorums).to be_empty
    end

    it "asks the configured authorization, so a host policy is consulted too (§9.2)" do
      ChangeRequests.config.authorization = ->(**) { false }

      expect(guard.eligible_quorums).to be_empty
    end
  end

  # §5.3, §7.1: the subset an approval actually links to. Under all_quorums it is a *strict* subset -
  # exactly one quorum - which is what stops one person closing two quorums that must both be met.
  describe "#countable_quorums" do
    let(:actor) { Admin.create!(name: "Ada", roles: %w(member_admin owner finance)) }

    def declare(satisfied_by)
      ChangeRequests.operations["members.update_roles"].workflow do |w|
        w.stage :approval, satisfied_by: satisfied_by do |q|
          q.quorum :admins,  permissions: %w(member_admin), threshold: 2
          q.quorum :owners,  permissions: %w(owner),        threshold: 2
          q.quorum :finance, permissions: %w(finance),      threshold: 2
        end
      end
    end

    def quorum(name)
      change_request.stages.sole.quorums.find_by!(name: name)
    end

    context "under any_quorum" do
      before { declare(:any_quorum) }

      it "links to every quorum the actor qualifies for - the alternatives are alternatives" do
        expect(guard.countable_quorums).to match_array(guard.eligible_quorums)
        expect(guard.countable_quorums.map(&:name)).to match_array(%w(admins owners finance))
      end
    end

    context "under all_quorums" do
      before { declare(:all_quorums) }

      it "links to exactly one, however many the actor qualifies for" do
        expect(guard.eligible_quorums.size).to eq(3)
        expect(guard.countable_quorums.size).to eq(1)
      end

      it "picks the lowest position, which is declaration order (§5.3)" do
        expect(guard.countable_quorums.map(&:name)).to eq(%w(admins))
      end

      it "is a strict subset of the quorums that made the actor eligible" do
        expect(guard.eligible_quorums).to include(*guard.countable_quorums)
      end

      # eligible_quorums is already scoped to pending ones, so a closed quorum is never the
      # lowest-position candidate and the next approval lands where there is still room.
      it "skips a quorum that is already satisfied" do
        quorum("admins").update!(status: "satisfied", satisfied_at: Time.current)

        expect(guard.countable_quorums.map(&:name)).to eq(%w(owners))
      end

      it "links to nothing when every quorum it qualifies for is satisfied" do
        change_request.stages.sole.quorums.update_all(status: "satisfied")

        expect(guard.countable_quorums).to be_empty
      end
    end

    # A stage of one quorum cannot tell the two rules apart, and must behave identically either way.
    context "with a single-quorum stage" do
      it "links to it under all_quorums" do
        expect(guard.countable_quorums.size).to eq(1)
      end
    end
  end
end
