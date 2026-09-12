# frozen_string_literal: true

require "rails_helper"

module JobProbes
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

# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "§8's background execution mode" do
  subject(:execute) { ChangeRequests::Commands::Execute.call(request: change_request, actor: executer) }

  let(:service) { "JobProbes::Roles" }
  let(:executer) { Manager.create!(id: "mgr-1", name: "Olive", roles: %w(ops)) }
  let(:requester) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                          requester: requester, payload: { "member_id" => "42" })
  end

  def declare
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = service
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
    end
  end

  def approve!
    ChangeRequests::Commands::Approve.call(
      request: change_request, actor: Admin.create!(name: "Amy", roles: %w(member_admin))
    )
  end

  def enqueued
    ActiveJob::Base.queue_adapter.enqueued_jobs
  end

  # Performed explicitly rather than through perform_enqueued_jobs, so the two phases stay
  # separable: what the claim left behind, and what the job then did with it.
  def perform_enqueued!
    enqueued.each { |job| job[:job].perform_now(*job[:args]) }
  end

  before do
    JobProbes::Roles.applied = nil
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    declare
    approve!
  end

  after { ChangeRequests.config.execution_mode = :inline }

  it "is defined here, the dummy application having loaded ActiveJob" do
    expect(ChangeRequests.background_available?).to be(true)
    expect(ChangeRequests::Execution::Job).to be < ActiveJob::Base
  end

  describe "inline, the default" do
    it "runs the target in the calling process and finishes the request" do
      execute

      expect(change_request.reload.status).to eq("successful")
      expect(JobProbes::Roles.applied).to eq("42")
      expect(enqueued).to be_empty
    end
  end

  describe "background" do
    before { ChangeRequests.config.execution_mode = :background }

    # §8: T1 still commits synchronously, so the UI shows `executing` immediately.
    it "claims the request synchronously and returns it already executing" do
      expect(execute.status).to eq("executing")
      expect(change_request.reload.attempts.sole).to have_attributes(number: 1, outcome: nil)
    end

    it "invokes nothing in the calling process" do
      execute

      expect(JobProbes::Roles.applied).to be_nil
    end

    it "emits execution_started before the job runs, so the timeline is not silent" do
      execute

      expect(change_request.reload.events.map(&:kind)).to include("execution_started")
      expect(change_request.events.map(&:kind)).not_to include("executed")
    end

    it "enqueues the configured job with the two ids" do
      execute

      expect(enqueued.sole).to include(job: ChangeRequests::Execution::Job, queue: "default")
      expect(enqueued.sole[:args])
        .to eq([change_request.id, change_request.reload.attempts.sole.id])
    end

    it "enqueues onto the configured queue" do
      ChangeRequests.config.job_queue = :low

      execute

      expect(enqueued.sole[:queue]).to eq("low")
    end

    it "completes the run when the job is performed" do
      execute
      perform_enqueued!

      expect(change_request.reload.status).to eq("successful")
      expect(JobProbes::Roles.applied).to eq("42")
      expect(change_request.attempts.sole.outcome).to eq("succeeded")
      expect(change_request.events.map(&:kind)).to include("executed")
    end

    # T3 reads the executer's triple off the attempt, which is how a process that never saw the
    # actor object still records who ran it (§5.6).
    it "records the executer who claimed it, not the process that settled it" do
      execute
      perform_enqueued!

      expect(change_request.reload.executer).to eq(type: "Manager", id: "mgr-1", label: "Olive")
      expect(change_request.events.find_by!(kind: "executed").actor_label).to eq("Olive")
    end

    context "when the target raises" do
      let(:service) { "JobProbes::Raises" }

      it "records the failure in the job, leaving the request failed" do
        execute

        expect { perform_enqueued! }.to raise_error(ChangeRequests::TargetFailed)

        expect(change_request.reload.status).to eq("failed")
        expect(change_request.attempts.sole).to have_attributes(outcome: "failed",
                                                                error_message: "the provider said no")
        expect(change_request.events.map(&:kind)).to include("execution_failed")
      end
    end

    it "refuses before claiming when the guard says no, enqueuing nothing" do
      other = ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                                    requester: requester)

      expect { ChangeRequests::Commands::Execute.call(request: other, actor: executer) }
        .to raise_error(ChangeRequests::NotExecutable)
      expect(enqueued).to be_empty
    end
  end
end
