# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Guards::Cancel do
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
    expect(described_class.error_class).to eq(ChangeRequests::NotCancelable)
  end

  describe "who may cancel (§7.2)" do
    it "allows the requester" do
      expect(described_class.new(request: change_request, actor: requester)).to be_allowed
    end

    it "allows an eligible approver of the current stage" do
      expect(guard).to be_allowed
    end

    # §7.2's preamble: "eligible approver" is not restricted to the current stage. Cancelling is a
    # judgement about the request as a whole.
    it "allows an approver eligible only on a later stage" do
      sign_off = change_request.stages.create!(position: 2, name: "sign_off")
      sign_off.quorums.create!(position: 1, threshold: 1).permissions.create!(permission: "director")
      director = Admin.create!(name: "Dora", roles: %w(director))

      expect(described_class.new(request: change_request, actor: director)).to be_allowed
    end

    it "refuses an actor who is neither" do
      expect(described_class.new(request: change_request, actor: Admin.create!(name: "Sam")).reason)
        .to eq(:not_permitted)
    end

    it "refuses an actor class that may not approve (§9.1)" do
      ChangeRequests.config.actor_types.fetch("Admin").may_approve = false

      expect(guard.reason).to eq(:not_permitted)
    end
  end

  describe "when it is permitted (§7.2)" do
    %w(pending approved failed).each do |status|
      it "allows a request that is #{status}" do
        change_request.update!(status: status)

        expect(guard).to be_allowed
      end
    end

    ChangeRequests::Request::FINAL_STATUSES.each do |status|
      it "refuses a request that is already #{status}" do
        change_request.update!(status: status)

        expect(guard.reason).to eq(:already_finalized)
      end
    end

    # The target is mid-flight: a status change cannot recall it, and setting a terminal status
    # would leave the execution unable to record its own outcome (§8).
    it "refuses a request that is executing" do
      change_request.update!(status: "executing")

      expect(guard.reason).to eq(:executing)
    end

    it "prefers :already_finalized over :not_permitted" do
      change_request.update!(status: "canceled")
      guard = described_class.new(request: change_request, actor: Admin.create!(name: "Sam"))

      expect(guard.reason).to eq(:already_finalized)
    end
  end

  # A request that is already over is the same refusal whichever command met it, and the model's
  # TerminalStateGuard raises exactly this with exactly this reason (§5.8).
  describe "the error a finished request raises" do
    before { change_request.update!(status: "successful") }

    it "is AlreadyFinalized, not the guard's declared class" do
      expect { guard.check! }.to raise_error(ChangeRequests::AlreadyFinalized) { |error|
        expect(error.reason).to eq(:already_finalized)
        expect(error.request).to eq(change_request)
      }
    end

    it "is still a TransitionError, so one rescue catches the family" do
      expect { guard.check! }.to raise_error(ChangeRequests::TransitionError)
    end

    it "matches what the model raises when a command is bypassed entirely" do
      expect { change_request.update!(status: "pending") }
        .to raise_error(ChangeRequests::AlreadyFinalized) { |error|
          expect(error.reason).to eq(:already_finalized)
        }
    end
  end

  it "raises its declared class for every other refusal" do
    guard = described_class.new(request: change_request, actor: Admin.create!(name: "Sam"))

    expect { guard.check! }.to raise_error(ChangeRequests::NotCancelable)
  end

  # A Cancel button is what opens the form that collects the reason (Q25).
  it "does not look at the reason" do
    expect(described_class.new(request: change_request, actor: actor, reason: nil)).to be_allowed
  end
end
