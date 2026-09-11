# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Guards::Unapprove do
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

  def approve_as(approver)
    ChangeRequests::Commands::Approve.call(request: change_request.reload, actor: approver)
  end

  it_behaves_like "a change request guard"

  it "refuses with its own error (§7)" do
    expect(described_class.error_class).to eq(ChangeRequests::NotUnapprovable)
  end

  describe "the happy path" do
    it "allows the approver while their stage is still open" do
      approve_as(actor)

      expect(described_class.new(request: change_request.reload, actor: actor)).to be_allowed
    end
  end

  describe ":not_the_approver" do
    it "refuses an actor who has decided nothing on this request" do
      approve_as(actor)
      other = Admin.create!(name: "Ben", roles: %w(member_admin))

      expect(described_class.new(request: change_request.reload, actor: other).reason)
        .to eq(:not_the_approver)
    end

    it "refuses when nobody has decided at all" do
      expect(guard.reason).to eq(:not_the_approver)
    end

    it "raises NotUnapprovable carrying the reason" do
      approve_as(actor)
      other = Admin.create!(name: "Ben", roles: %w(member_admin))
      guard = described_class.new(request: change_request.reload, actor: other)

      expect { guard.check! }.to raise_error(ChangeRequests::NotUnapprovable) { |error|
        expect(error.reason).to eq(:not_the_approver)
      }
    end

    # config.actor_identity says who counts as one person when tallying approvers (§9.4).
    # Retracting is about which row this actor wrote: one actor undoing another's row would make
    # the trail say something untrue.
    it "does not let a second actor class retract, even under config.actor_identity" do
      ChangeRequests.config.actor_identity = ->(person) { person.name }
      approve_as(actor)
      twin = User.create!(name: "Ada", email: "ada@example.com", roles: %w(member_admin))

      expect(described_class.new(request: change_request.reload, actor: twin).reason)
        .to eq(:not_the_approver)
    end
  end

  describe ":not_pending" do
    it "refuses once the request is approved (§7.2)" do
      approve_as(actor)
      change_request.update!(status: "approved")

      expect(described_class.new(request: change_request, actor: actor).reason).to eq(:not_pending)
    end

    %w(executing successful failed rejected canceled expired).each do |status|
      it "refuses a request that is #{status}" do
        approve_as(actor)
        change_request.update!(status: status)

        expect(described_class.new(request: change_request, actor: actor).reason).to eq(:not_pending)
      end
    end
  end

  # A closed stage is immutable and its outcome is a historical fact (§7.1).
  describe ":stage_not_open" do
    before do
      change_request.stages.create!(position: 2, name: "sign_off")
    end

    it "refuses once the stage they decided on has closed" do
      approve_as(actor)
      change_request.stages.first.update!(status: "closed", closed_at: Time.current)
      change_request.update!(current_stage_position: 2)

      expect(described_class.new(request: change_request.reload, actor: actor).reason)
        .to eq(:stage_not_open)
    end

    it "prefers :not_pending when the request itself is finished" do
      approve_as(actor)
      change_request.stages.first.update!(status: "closed", closed_at: Time.current)
      change_request.update!(current_stage_position: 2, status: "approved")

      expect(described_class.new(request: change_request.reload, actor: actor).reason)
        .to eq(:not_pending)
    end
  end

  describe "#decision" do
    it "is the row this actor wrote" do
      approve_as(actor)

      expect(described_class.new(request: change_request.reload, actor: actor).decision)
        .to eq(change_request.approvals.sole)
    end

    it "is nil when they wrote none" do
      expect(guard.decision).to be_nil
    end

    it "prefers the current stage when they decided on more than one" do
      change_request.stages.create!(position: 2, name: "sign_off")
      approve_as(actor)
      change_request.update!(current_stage_position: 2)
      later = change_request.stages.last.approvals.create!(
        change_request: change_request, approver: actor, decision: "approved", decided_at: Time.current
      )

      expect(described_class.new(request: change_request.reload, actor: actor).decision).to eq(later)
    end
  end
end
