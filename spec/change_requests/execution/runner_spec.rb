# frozen_string_literal: true

require "rails_helper"

# Real targets on real class methods. They record what they were handed in class-level state, which
# is safe here because these examples are single-threaded; the measured one below uses a queue.
module RunnerProbes
  class Succeeds
    class << self
      attr_accessor :calls

      def call(**payload)
        self.calls = (calls || []) << payload

        :done
      end
    end
  end

  class Raises
    class Boom < StandardError
    end

    def self.call(**)
      fail(Boom, "the payment provider timed out")
    end
  end

  class Counts
    class << self
      attr_accessor :count

      def call(**)
        self.count = (count || 0) + 1
      end
    end
  end
end

# The guard refuses a claimed request before T1's conditional UPDATE is ever reached, so the
# invariant beneath it is only observable with the guard out of the way - the inverse of M1b-15's
# UnlockedApprove, and measured rather than assumed for the same reason.
class UnguardedClaim < ChangeRequests::Commands::ClaimExecution
  def authorize!
    nil
  end
end

RSpec.describe ChangeRequests::Execution::Runner do
  subject(:run) { described_class.call(request: change_request, actor: executer) }

  let(:service) { "RunnerProbes::Succeeds" }
  let(:max_attempts) { 1 }
  let(:executer) { Manager.create!(id: "mgr-1", name: "Olive", roles: %w(ops)) }
  let(:requester) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:payload) { { "member_id" => "42" } }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                          requester: requester, payload: payload)
  end

  def declare(service:, max_attempts: 1)
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version      = "2026-09-12"
      op.service      = service
      op.max_attempts = max_attempts
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
    end
  end

  def approve!
    ChangeRequests::Commands::Approve.call(
      request: change_request, actor: Admin.create!(name: "Amy", roles: %w(member_admin))
    )
  end

  before do
    RunnerProbes::Succeeds.calls = nil
    RunnerProbes::Counts.count = nil
    declare(service: service, max_attempts: max_attempts)
    approve!
  end

  describe "a successful run (§8)" do
    it "returns the request, now successful" do
      expect(run).to be_a(ChangeRequests::Request)
      expect(change_request.reload.status).to eq("successful")
    end

    it "stamps executed_at and the executer's triple" do
      run

      expect(change_request.reload.executed_at).to be_within(5.seconds).of(Time.current)
      expect(change_request.executer)
        .to eq(type: "Manager", id: "mgr-1", label: "Olive")
    end

    it "writes exactly one attempt, succeeded and finished" do
      run
      attempt = change_request.attempts.sole

      expect(attempt).to have_attributes(number: 1, outcome: "succeeded")
      expect(attempt.started_at).to be_present
      expect(attempt.finished_at).to be_present
      expect(attempt.error_class).to be_nil
    end

    it "records who claimed it on the attempt too (§5.6)" do
      run

      expect(change_request.attempts.sole.executer)
        .to eq(type: "Manager", id: "mgr-1", label: "Olive")
    end

    it "emits execution_started and executed, in that order" do
      run

      expect(change_request.events.map(&:kind).last(2)).to eq(%w(execution_started executed))
    end

    it "names the attempt in both events, so a timeline says which run it was" do
      run
      events = change_request.events.where(kind: %w(execution_started executed))

      expect(events.map { |event| event.metadata["attempt"] }).to eq([1, 1])
    end

    it "dispatches the payload and the request id to the target (§6.12, §8)" do
      run

      expect(RunnerProbes::Succeeds.calls)
        .to eq([{ member_id: "42", change_request_id: change_request.id }])
    end

    context "with a counting target" do
      let(:service) { "RunnerProbes::Counts" }

      it "invokes it exactly once" do
        run

        expect(RunnerProbes::Counts.count).to eq(1)
      end
    end
  end

  describe "a target that raises (§8)" do
    let(:service) { "RunnerProbes::Raises" }

    it "raises TargetFailed, naming what it invoked" do
      expect { run }
        .to raise_error(ChangeRequests::TargetFailed, /RunnerProbes::Raises\.call raised/)
    end

    it "preserves the target's own error as #cause, which is the point of wrapping it" do
      expect { run }.to raise_error(ChangeRequests::TargetFailed) { |error|
        expect(error.cause).to be_a(RunnerProbes::Raises::Boom)
        expect(error.cause.message).to eq("the payment provider timed out")
      }
    end

    # T3's failure branch is its own transaction, so the record survives even though nothing the
    # target did does.
    it "leaves the request failed rather than executing" do
      expect { run }.to raise_error(ChangeRequests::TargetFailed)

      expect(change_request.reload.status).to eq("failed")
    end

    it "records the class, the message and a bounded backtrace on the attempt" do
      expect { run }.to raise_error(ChangeRequests::TargetFailed)
      attempt = change_request.attempts.sole

      expect(attempt).to have_attributes(outcome: "failed",
                                         error_class: "RunnerProbes::Raises::Boom",
                                         error_message: "the payment provider timed out")
      expect(attempt.finished_at).to be_present
      expect(attempt.backtrace.lines.size)
        .to be <= ChangeRequests::Commands::SettleExecution::BACKTRACE_FRAMES
    end

    it "emits execution_failed carrying the message and the error class" do
      expect { run }.to raise_error(ChangeRequests::TargetFailed)
      event = change_request.events.find_by!(kind: "execution_failed")

      expect(event.body).to eq("the payment provider timed out")
      expect(event.metadata).to include("error_class" => "RunnerProbes::Raises::Boom", "attempt" => 1)
    end

    # `failed` is not final: the approval stands, and max_attempts is the only thing bounding a
    # second go (§8).
    context "within a ceiling of two" do
      let(:max_attempts) { 2 }

      it "is retryable until the ceiling is spent, then refused" do
        expect { run }.to raise_error(ChangeRequests::TargetFailed)
        expect(change_request.reload).to be_retryable

        expect { described_class.call(request: change_request, actor: executer) }
          .to raise_error(ChangeRequests::TargetFailed)
        expect(change_request.reload).not_to be_retryable

        expect { described_class.call(request: change_request, actor: executer) }
          .to raise_error(ChangeRequests::NotExecutable) { |error|
            expect(error.reason).to eq(:attempts_exhausted)
          }
        expect(change_request.attempts.count).to eq(2)
      end
    end
  end

  describe "the guard runs inside T1 (§8)" do
    it "refuses a request nobody approved, before any attempt exists" do
      request = ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                                      requester: requester, payload: payload)

      expect { described_class.call(request: request, actor: executer) }
        .to raise_error(ChangeRequests::NotExecutable) { |error|
          expect(error.reason).to eq(:not_approved)
        }
      expect(request.attempts).to be_empty
    end

    # The claimed-request race, answered by the guard because it reads the row it locked. T1's
    # conditional UPDATE is the invariant beneath it, asserted separately below.
    it "refuses a request already claimed by another process" do
      change_request.update!(status: "executing")

      expect { run }.to raise_error(ChangeRequests::NotExecutable) { |error|
        expect(error.reason).to eq(:executing)
      }
      expect(RunnerProbes::Succeeds.calls).to be_nil
    end
  end

  # The floor beneath the guard: whatever route reaches T1, a claimed row cannot be claimed twice.
  describe "T1's conditional UPDATE" do
    subject(:claim) { UnguardedClaim.call(request: change_request, actor: executer) }

    it "claims an approved request when nothing else has" do
      expect(claim.number).to eq(1)
      expect(change_request.reload.status).to eq("executing")
    end

    it "raises ExecutionInProgress when the status moved under it" do
      ChangeRequests::Request.where(id: change_request.id).update_all(status: "executing")

      expect { claim }.to raise_error(ChangeRequests::ExecutionInProgress, /already being executed/)
    end

    it "raises it without writing an attempt, so the ceiling is not spent by a lost race" do
      ChangeRequests::Request.where(id: change_request.id).update_all(status: "executing")

      expect { claim }.to raise_error(ChangeRequests::ExecutionInProgress)
      expect(change_request.attempts).to be_empty
    end

    # The unique index on (change_request_id, number) is the claim's second lock (§5.6).
    # next_number_for counts rows, so a gap makes it hand back a number that already exists -
    # the same collision two processes reach when they both compute the same next number (§5.6).
    it "raises ExecutionInProgress when the attempt number is already taken" do
      change_request.attempts.create!(number: 2, started_at: Time.current)

      expect { claim }.to raise_error(ChangeRequests::ExecutionInProgress)
      expect(change_request.attempts.pluck(:number)).to eq([2])
    end
  end
end
