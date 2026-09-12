# frozen_string_literal: true

require "rails_helper"

module ExecuteProbes
  class Roles
    class << self
      attr_accessor :applied

      def call(member_id:, **)
        self.applied = member_id
      end
    end
  end

  class Raises
    def self.call(**)
      fail("the provider said no")
    end
  end
end

RSpec.describe ChangeRequests::Commands::Execute do
  subject(:execute) { described_class.call(request: change_request, actor: executer) }

  let(:service) { "ExecuteProbes::Roles" }
  let(:executer) { Manager.create!(id: "mgr-1", name: "Olive", roles: %w(ops)) }
  let(:requester) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                          requester: requester, payload: { "member_id" => "42" })
  end

  def declare(service_name = service)
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = service_name
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
    end
  end

  def approve!
    ChangeRequests::Commands::Approve.call(
      request: change_request, actor: Admin.create!(name: "Amy", roles: %w(member_admin))
    )
  end

  before do
    ExecuteProbes::Roles.applied = nil
    declare
  end

  describe "the shape every other command has (§6.6)" do
    before { approve! }

    it "takes the request and the acting actor, and returns the request" do
      expect(execute).to be_a(ChangeRequests::Request)
      expect(change_request.reload.status).to eq("successful")
    end

    it "runs the target, which is the whole point of the deferral" do
      execute

      expect(ExecuteProbes::Roles.applied).to eq("42")
    end

    it "drives §8's three transactions rather than doing the work itself" do
      execute

      expect(change_request.reload.attempts.sole).to have_attributes(number: 1, outcome: "succeeded")
      expect(change_request.events.map(&:kind).last(2)).to eq(%w(execution_started executed))
    end

    context "when the target raises" do
      let(:service) { "ExecuteProbes::Raises" }

      it "raises TargetFailed and records the failure (§8)" do
        expect { execute }.to raise_error(ChangeRequests::TargetFailed)

        expect(change_request.reload.status).to eq("failed")
        expect(change_request.attempts.sole.outcome).to eq("failed")
      end
    end
  end

  # §6.6's worked example, run as written: the two approvals the operation demanded, the
  # requester refused her own request, and the effect happening now and not before.
  describe "§6.6, end to end" do
    let(:bob) { Admin.create!(name: "Bob", roles: %w(member_admin)) }
    let(:carol) { Admin.create!(name: "Carol", roles: %w(member_admin)) }

    before do
      ChangeRequests.operations["members.update_roles"].workflow do |w|
        w.stage :approval, permissions: %w(member_admin), threshold: 2
      end
    end

    it "walks pending, approved, successful - and runs the target only at the end" do
      expect(change_request.status).to eq("pending")

      ChangeRequests::Commands::Approve.call(request: change_request, actor: bob)

      expect(change_request.reload.status).to eq("pending")
      expect(ExecuteProbes::Roles.applied).to be_nil

      ChangeRequests::Commands::Approve.call(request: change_request, actor: carol)

      expect(change_request.reload.status).to eq("approved")
      expect(ExecuteProbes::Roles.applied).to be_nil

      described_class.call(request: change_request, actor: carol)

      expect(change_request.reload.status).to eq("successful")
      expect(ExecuteProbes::Roles.applied).to eq("42")
    end

    it "refuses the requester her own approval, which is the point" do
      expect { ChangeRequests::Commands::Approve.call(request: change_request, actor: requester) }
        .to raise_error(ChangeRequests::NotApprovable) { |error|
          expect(error.reason).to eq(:requester)
        }
    end
  end

  # The acceptance: the guard's refusals now reach a caller through the command. The guard runs
  # inside T1, against the row it locked - so these are the same answers its own truth table gives.
  describe "the guard's refusals, through the command (§7.2)" do
    def reason_for
      execute

      nil
    rescue ChangeRequests::TransitionError, ChangeRequests::NotAuthorized => e
      e.reason
    end

    it "refuses a request nobody has approved" do
      expect(reason_for).to eq(:not_approved)
    end

    it "refuses a request that is already being executed" do
      change_request.update!(status: "executing")

      expect(reason_for).to eq(:executing)
    end

    it "refuses a request that is already finished" do
      approve!
      change_request.update!(status: "successful")

      expect(reason_for).to eq(:already_finalized)
    end

    it "refuses a failed request whose attempts are spent" do
      approve!
      change_request.update!(status: "failed")
      change_request.attempts.create!(number: 1, started_at: Time.current, outcome: "failed")

      expect(reason_for).to eq(:attempts_exhausted)
    end

    it "refuses the requester unless the host says otherwise (§8)" do
      approve!

      expect { described_class.call(request: change_request, actor: requester) }
        .to raise_error(ChangeRequests::NotExecutable) { |error|
          expect(error.reason).to eq(:requester)
        }
    end

    it "refuses an operation that is no longer declared (§5.11)" do
      approve!
      ChangeRequests.operations.clear

      expect(reason_for).to eq(:operation_undeclared)
    end

    it "raises NotExecutable, which is what §6.6 says a controller rescues" do
      expect { execute }.to raise_error(ChangeRequests::NotExecutable)
    end

    it "invokes nothing when it refuses" do
      expect { execute }.to raise_error(ChangeRequests::NotExecutable)

      expect(ExecuteProbes::Roles.applied).to be_nil
      expect(change_request.attempts).to be_empty
    end
  end

  # §8 forbids a lock across T2, so this command takes none of its own - the runner's three are
  # the only ones. spec/integration/concurrency_spec.rb measures that; this states the structure.
  describe "the lock" do
    it "opens none of its own, leaving all three to the runner (§8)" do
      command = described_class.new(request: change_request, actor: executer)

      expect(command.around_perform { :ran }).to eq(:ran)
    end
  end
end
