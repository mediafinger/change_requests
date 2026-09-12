# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Guards::Execute do
  subject(:guard) { described_class.new(request: change_request, actor: actor) }

  let(:actor) { Admin.create!(name: "Olive", roles: %w(ops)) }
  let(:approver) { Admin.create!(name: "Ada", roles: %w(member_admin)) }
  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "Members::UpdateRoles"
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
    end
  end

  def approved!
    ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)
    change_request.update!(status: "approved")

    change_request.reload
  end

  it_behaves_like "a change request guard"

  it "refuses with NotExecutable (§7)" do
    expect(described_class.error_class).to eq(ChangeRequests::NotExecutable)
  end

  describe "the happy path" do
    it "allows a neutral actor on an approved request" do
      approved!

      expect(guard).to be_allowed
    end
  end

  # Order decides which reason a user sees, so it is asserted, not assumed.
  describe "the branch order" do
    it "prefers :already_finalized over :not_approved, because already done beats never approved" do
      change_request.update!(status: "successful")

      expect(guard.reason).to eq(:already_finalized)
    end

    it "prefers :not_approved over the separation-of-duties branches" do
      guard = described_class.new(request: change_request, actor: requester)

      expect(guard.reason).to eq(:not_approved)
    end

    it "prefers :attempts_exhausted over :requester" do
      approved!
      change_request.update!(status: "failed")
      change_request.attempts.create!(number: 1)

      expect(described_class.new(request: change_request.reload, actor: requester).reason)
        .to eq(:attempts_exhausted)
    end
  end

  describe ":already_finalized" do
    ChangeRequests::Request::FINAL_STATUSES.each do |status|
      it "refuses a request that is #{status}" do
        change_request.update!(status: status)

        expect(guard.reason).to eq(:already_finalized)
      end
    end

    it "raises AlreadyFinalized through the shared mapping, not the declared class (Q29)" do
      change_request.update!(status: "successful")

      expect { guard.check! }.to raise_error(ChangeRequests::AlreadyFinalized)
    end
  end

  describe ":not_approved" do
    it "refuses a request that is pending" do
      change_request.update!(status: "pending")

      expect(guard.reason).to eq(:not_approved)
    end
  end

  # Split from :not_approved by M3a-2: a claimed request *is* approved, and telling an operator it
  # is not approved while its target runs is simply untrue. Guards::Cancel already uses the reason.
  describe ":executing" do
    it "refuses a request whose target is already running" do
      change_request.update!(status: "executing")

      expect(guard.reason).to eq(:executing)
    end
  end

  # Split from :not_approved so a host can tell a retry that ran out from a request nobody approved.
  # max_attempts is readonly after create, so the ceiling is set on the declaration, as a host would.
  describe ":attempts_exhausted" do
    def failed_after(attempts, ceiling: 1)
      ChangeRequests.operations["members.update_roles"].max_attempts = ceiling
      approved!
      change_request.update!(status: "failed")
      attempts.times { |i| change_request.attempts.create!(number: i + 1) }

      change_request.reload
    end

    it "allows a failed request below its ceiling (§8)" do
      expect(described_class.new(request: failed_after(1, ceiling: 3), actor: actor)).to be_allowed
    end

    it "refuses a failed request at its ceiling" do
      expect(described_class.new(request: failed_after(2, ceiling: 2), actor: actor).reason)
        .to eq(:attempts_exhausted)
    end

    it "refuses a failed request that has spent its single default attempt" do
      expect(described_class.new(request: failed_after(1), actor: actor).reason)
        .to eq(:attempts_exhausted)
    end

    it "does not apply to an approved request that has never been attempted" do
      approved!

      expect(guard).to be_allowed
    end
  end

  # §9.1's third registration flag, which nothing read until now.
  describe "may_execute" do
    before { approved! }

    it "refuses an actor class that declares may_execute = false" do
      ChangeRequests.config.actor_types.fetch("Admin").may_execute = false

      expect(guard.reason).to eq(:not_permitted)
    end

    it "outranks the separation-of-duties settings" do
      ChangeRequests.config.actor_types.fetch("Admin").may_execute = false
      ChangeRequests.config.approver_may_execute = true

      expect(described_class.new(request: change_request, actor: approver).reason)
        .to eq(:not_permitted)
    end

    it "refuses an actor whose class is not registered at all (§9.1)" do
      expect { described_class.new(request: change_request, actor: Object.new).reason }
        .to raise_error(ChangeRequests::UnknownActorType)
    end
  end

  # The truth table the acceptance asks for: statuses x actor roles x both settings.
  describe "separation of duties (§8)" do
    before { approved! }

    context "the requester" do
      subject(:guard) { described_class.new(request: change_request, actor: requester) }

      it "is refused by default, because requester_may_execute is false" do
        expect(ChangeRequests.config.requester_may_execute).to be(false)
        expect(guard.reason).to eq(:requester)
      end

      it "is allowed when the host opts in" do
        ChangeRequests.config.requester_may_execute = true

        expect(guard).to be_allowed
      end

      # The same helper Approve uses, so "is this the same human" is answered identically (§9.4).
      # requester_identity is snapshotted at creation, so the lambda has to be in place first - which
      # is what makes the M1b-4 column, rather than a live lookup, the thing that closes the hole.
      it "sees through two actor classes under config.actor_identity" do
        ChangeRequests.config.actor_identity = ->(person) { person.name }
        fresh = ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                                      requester: requester)
        ChangeRequests::Commands::Approve.call(request: fresh, actor: approver)
        fresh.update!(status: "approved")
        twin = Admin.create!(name: "Rita")

        expect(described_class.new(request: fresh.reload, actor: twin).reason).to eq(:requester)
      end
    end

    context "an approver on this request" do
      subject(:guard) { described_class.new(request: change_request, actor: approver) }

      it "is allowed by default, because approver_may_execute is true" do
        expect(ChangeRequests.config.approver_may_execute).to be(true)
        expect(guard).to be_allowed
      end

      it "is refused when the host turns it off" do
        ChangeRequests.config.approver_may_execute = false

        expect(guard.reason).to eq(:not_permitted)
      end

      # "An approver on this request" means they wrote a row, not that they were eligible to.
      it "means having decided, not having been eligible to decide" do
        ChangeRequests.config.approver_may_execute = false
        eligible_but_silent = Admin.create!(name: "Ben", roles: %w(member_admin))

        expect(described_class.new(request: change_request, actor: eligible_but_silent)).to be_allowed
      end

      it "counts a rejection as having decided" do
        ChangeRequests.config.approver_may_execute = false
        rejector = Admin.create!(name: "Cara", roles: %w(member_admin))
        change_request.stages.sole.approvals.create!(
          change_request: change_request, approver: rejector,
          decision: "rejected", decided_at: Time.current
        )

        expect(described_class.new(request: change_request.reload, actor: rejector).reason)
          .to eq(:not_permitted)
      end
    end

    context "a neutral actor" do
      it "is allowed whatever either setting says" do
        ChangeRequests.config.requester_may_execute = true
        ChangeRequests.config.approver_may_execute  = false

        expect(guard).to be_allowed
      end
    end
  end
end
