# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Guards::Reject do
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
      op.approvals permissions: %w(member_admin), required: 2
    end
  end

  it_behaves_like "a change request guard"

  it "refuses with its own error (§7)" do
    expect(described_class.error_class).to eq(ChangeRequests::NotRejectable)
  end

  describe "who may reject (§7.2)" do
    it "allows an eligible approver of the current stage" do
      expect(guard).to be_allowed
    end

    # Stopping something you asked for needs no four-eyes, which is why this is the one decision
    # the requester may take on their own request.
    it "allows the requester, who may always stop their own request" do
      expect(described_class.new(request: change_request, actor: requester)).to be_allowed
    end

    it "refuses an actor who is neither" do
      expect(described_class.new(request: change_request, actor: Admin.create!(name: "Sam")).reason)
        .to eq(:not_permitted)
    end

    it "refuses an actor class that may not approve (§9.1)" do
      ChangeRequests.config.actor_types.fetch("Admin").may_approve = false

      expect(guard.reason).to eq(:not_permitted)
    end

    it "raises NotRejectable carrying the reason" do
      guard = described_class.new(request: change_request, actor: Admin.create!(name: "Sam"))

      expect { guard.check! }.to raise_error(ChangeRequests::NotRejectable) { |error|
        expect(error.reason).to eq(:not_permitted)
      }
    end
  end

  describe ":not_pending" do
    %w(approved executing successful failed rejected canceled expired).each do |status|
      it "refuses a request that is #{status}" do
        change_request.update!(status: status)

        expect(guard.reason).to eq(:not_pending)
      end
    end
  end

  # Mirrors Approve: "not your turn yet" is a different answer from "you cannot reject this at all".
  describe ":stage_not_current" do
    before do
      sign_off = change_request.stages.create!(position: 2, name: "sign_off")
      quorum = sign_off.quorums.create!(position: 1, threshold: 1)
      quorum.permissions.create!(permission: "director")
    end

    it "refuses an actor eligible only on a later stage" do
      director = Admin.create!(name: "Dora", roles: %w(director))

      expect(described_class.new(request: change_request, actor: director).reason)
        .to eq(:stage_not_current)
    end

    it "still allows the requester, whose right does not depend on a stage" do
      expect(described_class.new(request: change_request, actor: requester)).to be_allowed
    end
  end

  describe ":already_decided" do
    it "refuses a second decision on the same stage" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: actor)

      expect(described_class.new(request: change_request.reload, actor: actor).reason)
        .to eq(:already_decided)
    end

    # The unique index is what guarantees a rejector cannot later approve that stage (§7.1).
    it "refuses a rejector who already spent their decision" do
      ChangeRequests.config.only_record_rejections = true
      ChangeRequests::Commands::Reject.call(request: change_request, actor: actor, reason: "No")

      expect(described_class.new(request: change_request.reload, actor: actor).reason)
        .to eq(:already_decided)
    end
  end

  # A Reject button is what opens the form that collects the reason, so the guard that decides
  # whether to show the button cannot depend on having one (Q25).
  describe "the mandatory reason" do
    it "is not the guard's business" do
      expect(described_class.new(request: change_request, actor: actor, reason: nil)).to be_allowed
    end

    it "never returns :reason_required" do
      expect(guard.reason).to be_nil
    end
  end
end
