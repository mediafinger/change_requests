# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Commands::Expire do
  subject(:expire) { described_class.call(request: change_request) }

  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version    = "2026-09-12"
      op.service    = "Members::UpdateRoles"
      op.expires_in = 7.days
      op.approvals permissions: %w(member_admin), required: 2
    end

    change_request.update_columns(expires_at: 1.minute.ago)
    change_request.reload
  end

  describe "what it does" do
    it "sets the request expired, which is final" do
      expire

      expect(change_request.reload.status).to eq("expired")
      expect(change_request).to be_final
    end

    it "leaves the request untouchable afterwards (§5.8)" do
      expire

      expect { change_request.reload.update!(status: "pending") }
        .to raise_error(ChangeRequests::AlreadyFinalized)
    end

    it "expires an approved request that was never executed (§7.2)" do
      change_request.update!(status: "approved")

      expire

      expect(change_request.reload.status).to eq("expired")
    end

    it "leaves the stages and approvals as they were" do
      approver = Admin.create!(name: "Ada", roles: %w(member_admin))
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)

      described_class.call(request: change_request.reload)

      expect(change_request.reload.approvals.count).to eq(1)
      expect(change_request.stages.sole.status).to eq("pending")
    end

    it "returns the request" do
      expect(expire).to eq(change_request)
    end
  end

  # The acceptance: gem-originated events are attributed to a sentinel, never to NULL (§19.15).
  describe "the expired event (§5.5)" do
    subject(:event) do
      expire

      change_request.events.find_by(kind: "expired")
    end

    it "emits exactly one" do
      expire

      expect(change_request.events.where(kind: "expired").count).to eq(1)
    end

    it "carries the System sentinel actor" do
      expect(event.actor).to eq(ChangeRequests::SYSTEM_ACTOR)
    end

    it "says so through the model's own predicate" do
      expect(event).to be_system_actor
    end

    it "uses a non-numeric id no host actor's key can collide with (§19.15)" do
      expect(event.actor_id).to eq("system")
    end

    it "never names System as a registered actor type" do
      expire

      expect(ChangeRequests.config.actor_types.keys).not_to include("System")
    end

    # Recorded before the status changes, so the trail says what expired rather than what it became.
    it "records the status the request expired out of" do
      change_request.update!(status: "approved")

      expect(event.metadata).to include("status" => "approved")
    end

    it "records the deadline it passed" do
      expect(event.metadata["expires_at"]).to be_present
    end

    it "carries no body - nobody wrote a reason, the clock ran out" do
      expect(event.body).to be_nil
    end
  end

  describe "the guard" do
    # The acceptance: an actor-supplied call raises NotAuthorized.
    it "refuses a call that supplies an actor, writing nothing" do
      expect { described_class.call(request: change_request, actor: Admin.create!(name: "Ada")) }
        .to raise_error(ChangeRequests::NotAuthorized) { |error|
          expect(error.reason).to eq(:not_system)
        }

      expect(change_request.reload.status).to eq("pending")
      expect(change_request.events.where(kind: "expired")).to be_empty
    end

    # The acceptance: a request not yet past expires_at raises.
    it "refuses a request whose expiry has not arrived" do
      change_request.update_columns(expires_at: 1.hour.from_now)

      expect { described_class.call(request: change_request.reload) }
        .to raise_error(ChangeRequests::NotAuthorized) { |error|
          expect(error.reason).to eq(:not_expired)
        }
    end

    it "refuses a request with no expiry at all" do
      change_request.update_columns(expires_at: nil)

      expect { described_class.call(request: change_request.reload) }
        .to raise_error(ChangeRequests::NotAuthorized) { |error|
          expect(error.reason).to eq(:not_expired)
        }
    end

    it "refuses a request that is already over" do
      change_request.update!(status: "canceled")

      expect { expire }.to raise_error(ChangeRequests::AlreadyFinalized)
    end

    it "refuses an operation that is no longer declared (§5.11)" do
      change_request
      ChangeRequests.operations.clear

      expect { expire }.to raise_error(ChangeRequests::NotAuthorized) { |error|
        expect(error.reason).to eq(:operation_undeclared)
      }
    end
  end

  # Maintenance.expire_stale! is M3b; this is the transition only. The scope it will sweep already
  # exists, so the two agree from the start.
  describe "what the M3b sweeper will select" do
    it "includes this request" do
      expect(ChangeRequests::Request.expired_candidates).to include(change_request)
    end

    it "drops it once it has expired" do
      expire

      expect(ChangeRequests::Request.expired_candidates).not_to include(change_request)
    end

    it "agrees with the guard on every status" do
      swept = ChangeRequests::Request::STATUSES.select do |status|
        change_request.update_columns(status: status)
        ChangeRequests::Request.expired_candidates.exists?(id: change_request.id)
      end

      allowed = ChangeRequests::Request::STATUSES.select do |status|
        change_request.update_columns(status: status)
        ChangeRequests::Guards::Expire.new(request: change_request.reload, actor: nil).allowed?
      end

      expect(swept).to eq(allowed)
    end
  end
end
