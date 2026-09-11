# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Guards::Comment do
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

  it "refuses with NotAuthorized - the actor may never comment, rather than not yet (§8)" do
    expect(described_class.error_class).to eq(ChangeRequests::NotAuthorized)
  end

  # The one guard on the far side of the exemption the shared example has been testing against a
  # probe class since M1b-1.
  it "is the exempt guard (§5.11, I8)" do
    expect(described_class.exempt_from_undeclared_operation).to be(true)
  end

  describe "who may comment (§7.2)" do
    it "allows the requester" do
      expect(described_class.new(request: change_request, actor: requester)).to be_allowed
    end

    it "allows an eligible approver of the current stage" do
      expect(guard).to be_allowed
    end

    # "Eligible approver" is not restricted to the current stage: a stage-three director may
    # comment on a request sitting in stage one (§7.2 preamble).
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
  end

  # Post-mortem notes on a finished request are the point of an audit trail, and a comment writes
  # no request column so the terminal-state guard is never in its way (§5.5).
  describe "permitted always" do
    (ChangeRequests::Request::STATUSES - ["pending"]).each do |status|
      it "allows a comment on a #{status} request" do
        change_request.update!(status: status)

        expect(guard).to be_allowed
      end
    end

    it "allows a comment when the operation is no longer declared (§5.11)" do
      change_request
      ChangeRequests.operations.clear

      expect(guard).to be_allowed
    end

    it "allows both at once - a finished request whose operation was removed" do
      change_request.update!(status: "successful")
      ChangeRequests.operations.clear

      expect(guard).to be_allowed
    end
  end

  # Guards::Base#check! builds whichever class a guard declared with request: and reason:. Before
  # NotAuthorized carried them, Ruby folded the keywords into the message and the reason vanished.
  describe "the error it raises" do
    subject(:guard) { described_class.new(request: change_request, actor: Admin.create!(name: "Sam")) }

    it "carries the reason hosts branch on" do
      expect { guard.check! }.to raise_error(ChangeRequests::NotAuthorized) { |error|
        expect(error.reason).to eq(:not_permitted)
      }
    end

    it "carries the request" do
      expect { guard.check! }.to raise_error(ChangeRequests::NotAuthorized) { |error|
        expect(error.request).to eq(change_request)
      }
    end

    it "reads as the refusal, not as an inspected hash" do
      expect { guard.check! }
        .to raise_error(ChangeRequests::NotAuthorized, "You are not one of this request's approvers.")
    end

    # §8 keeps the two apart: "may never" is not "not yet", and a host rescues them separately.
    it "is not a TransitionError" do
      expect { guard.check! }.to raise_error(ChangeRequests::NotAuthorized)
      expect(ChangeRequests::NotAuthorized.ancestors).not_to include(ChangeRequests::TransitionError)
    end

    it "is still a ChangeRequests::Error, so one rescue_from catches everything" do
      expect { guard.check! }.to raise_error(ChangeRequests::Error)
    end
  end
end
