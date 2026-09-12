# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Guards::Expire do
  subject(:guard) { described_class.new(request: change_request, actor: nil) }

  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version    = "2026-09-12"
      op.service    = "Members::UpdateRoles"
      op.expires_in = 7.days
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
    end
  end

  def past_its_expiry
    change_request.update_columns(expires_at: 1.minute.ago)

    change_request.reload
  end

  it_behaves_like "a change request guard"

  it "refuses with NotAuthorized - nobody expires a request on purpose (§8)" do
    expect(described_class.error_class).to eq(ChangeRequests::NotAuthorized)
  end

  describe "the happy path" do
    it "allows a pending request past its expiry" do
      past_its_expiry

      expect(guard).to be_allowed
    end

    it "allows an approved request past its expiry (§7.2)" do
      past_its_expiry
      change_request.update!(status: "approved")

      expect(guard).to be_allowed
    end
  end

  # System only: expiry has no human behind it, so an actor being supplied at all is the refusal.
  describe ":not_system" do
    it "refuses a call that supplies an actor" do
      past_its_expiry
      guard = described_class.new(request: change_request, actor: Admin.create!(name: "Ada"))

      expect(guard.reason).to eq(:not_system)
    end

    it "raises NotAuthorized carrying the reason" do
      past_its_expiry
      guard = described_class.new(request: change_request, actor: Admin.create!(name: "Ada"))

      expect { guard.check! }.to raise_error(ChangeRequests::NotAuthorized) { |error|
        expect(error.reason).to eq(:not_system)
        expect(error.request).to eq(change_request)
      }
    end

    it "outranks every other refusal, including an unexpired request" do
      guard = described_class.new(request: change_request, actor: Admin.create!(name: "Ada"))

      expect(guard.reason).to eq(:not_system)
    end
  end

  describe ":not_expired" do
    it "refuses a request whose expiry has not arrived" do
      expect(change_request.expires_at).to be > Time.current

      expect(guard.reason).to eq(:not_expired)
    end

    # A null expires_at never expires (§5.1), and that is the default.
    it "refuses a request that has no expiry at all" do
      change_request.update_columns(expires_at: nil)

      expect(described_class.new(request: change_request.reload, actor: nil).reason)
        .to eq(:not_expired)
    end

    it "allows one whose expiry has just passed" do
      change_request.update_columns(expires_at: Time.current)

      expect(described_class.new(request: change_request.reload, actor: nil)).to be_allowed
    end
  end

  describe ":not_expirable" do
    # `approved` is permitted, so :not_pending would be a lie here - the symbol is the contract.
    %w(executing failed).each do |status|
      it "refuses a request that is #{status}" do
        past_its_expiry
        change_request.update!(status: status)

        expect(guard.reason).to eq(:not_expirable)
      end
    end
  end

  describe ":already_finalized" do
    ChangeRequests::Request::FINAL_STATUSES.each do |status|
      it "refuses a request that is already #{status}" do
        past_its_expiry
        change_request.update!(status: status)

        expect(guard.reason).to eq(:already_finalized)
      end
    end

    it "raises AlreadyFinalized through the shared mapping, not the declared class" do
      past_its_expiry
      change_request.update!(status: "successful")

      expect { guard.check! }.to raise_error(ChangeRequests::AlreadyFinalized)
    end
  end
end
