# frozen_string_literal: true

require "rails_helper"

# The races M1's code can actually lose (§15.3). The execution races are M3a's.
#
# Real threads, real connections, real PostgreSQL - and committed rows, which is why this group
# opts out of the suite's transaction and truncates instead (see spec/support/concurrency.rb).
# Probe commands for the lock measurements below. Subclasses rather than mocks: rspec-mocks is not
# thread-safe, and these are invoked from real threads.
class TimedApprove < ChangeRequests::Commands::Approve
  HELD_OPEN = 0.05

  # Holds the body open long enough that two unserialised runs must overlap, and records the span.
  def perform
    options.fetch(:overlap).record do
      sleep HELD_OPEN

      super
    end
  end
end

# The same command with the lock taken away, and nothing else changed.
class UnlockedApprove < TimedApprove
  def around_perform
    yield
  end
end

# A target that stops inside T2 and waits, so the row can be inspected while it runs. Queues
# rather than sleeps: the handshake is deterministic and the spec has no timing window.
class BlockingTarget
  class << self
    attr_accessor :entered, :release

    def call(**)
      entered << :in
      release.pop

      :done
    end
  end
end

# The runner with the three transactions wrongly collapsed under one lock - the teeth for the
# measurement below, in the same shape as UnlockedApprove: same probe, one thing changed,
# opposite result. Without it, a NOWAIT that always succeeds would look like proof.
class LockedRunner < ChangeRequests::Execution::Runner
  def call
    request.with_lock { super }
  end
end

# The teeth for M3a-4: a count, not a timing window. A Mutex rather than a bare `+= 1`, because a
# lost update would make a double execution look like a single one - which is the bug being hunted.
class CountingTarget
  MUTEX = Mutex.new

  class << self
    attr_accessor :count

    def call(**)
      MUTEX.synchronize { self.count = count.to_i + 1 }

      :done
    end
  end
end

class FailingTarget
  def self.call(**)
    fail("the provider said no")
  end
end

# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "concurrency", :concurrent do
  self.use_transactional_tests = false

  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  # Registered before any thread is spawned. spec/support/global_state.rb hands the example a `dup`
  # of the config and operations memos, and a thread that mutated them would be writing to the main
  # thread's copy - so inside the threads the registry is read-only.
  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "Members::UpdateRoles"
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
    end
    # Built here too, before anything is spawned. RSpec's memoized helpers are not synchronised, so
    # a `let` first touched inside a thread is a race of its own - and two threads can each end up
    # with their own copy of what was meant to be one row.
    change_request
  end

  def approver(name)
    Admin.create!(name: name, roles: %w(member_admin))
  end

  def reload
    ChangeRequests::Request.find(change_request.id)
  end

  # 1. Two approvals racing the last slot of a quorum.
  describe "two approvals racing the last slot" do
    let(:first) { approver("Ada") }
    let(:second) { approver("Ben") }
    let(:third) { approver("Cara") }

    before do
      ChangeRequests.operations["members.update_roles"]
                    .workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
      ChangeRequests::Commands::Approve.call(request: change_request, actor: first)
    end

    it "lets exactly one of them transition the stage" do
      actors = [second, third]
      ChangeRequests::Testing.in_parallel(2) do |i|
        ChangeRequests::Commands::Approve.call(request: reload, actor: actors[i])
      end

      expect(reload.status).to eq("approved")
      expect(reload.stages.sole.status).to eq("closed")
    end

    it "closes the stage once, not once per thread" do
      actors = [second, third]
      ChangeRequests::Testing.in_parallel(2) do |i|
        ChangeRequests::Commands::Approve.call(request: reload, actor: actors[i])
      end

      expect(reload.events.where(kind: "stage_satisfied").count).to eq(1)
      expect(reload.events.where(kind: "quorum_satisfied").count).to eq(1)
    end

    # Two approvals meet the threshold and close the stage, so the third arrives at a request that
    # is already `approved` - and is told so rather than being recorded against a closed stage.
    it "records the two that fit and refuses the one that does not" do
      actors = [second, third]
      results = ChangeRequests::Testing.in_parallel(2) do |i|
        ChangeRequests::Commands::Approve.call(request: reload, actor: actors[i])
      end
      loser = results.find { |r| r.is_a?(Exception) }

      expect(reload.approvals.count).to eq(2)
      expect(loser).to be_a(ChangeRequests::NotApprovable)
      expect(loser.reason).to eq(:not_pending)
    end
  end

  # 2. The same actor approving twice. The unique index is what decides this one; the lock only
  # narrows the window. §15.3: it must surface as NotApprovable, never as a 500.
  describe "the same actor approving twice" do
    let(:actor) { approver("Ada") }

    it "lets exactly one through" do
      results = ChangeRequests::Testing.in_parallel(2) do
        ChangeRequests::Commands::Approve.call(request: reload, actor: actor)
      end

      expect(results.count { |r| r.is_a?(ChangeRequests::Request) }).to eq(1)
      expect(reload.approvals.count).to eq(1)
    end

    it "tells the loser NotApprovable(:already_decided), not RecordNotUnique" do
      results = ChangeRequests::Testing.in_parallel(2) do
        ChangeRequests::Commands::Approve.call(request: reload, actor: actor)
      end
      loser = results.find { |r| r.is_a?(Exception) }

      expect(loser).to be_a(ChangeRequests::NotApprovable)
      expect(loser.reason).to eq(:already_decided)
    end

    # The mapping is what turns the database's answer into the gem's. Without it the loser gets an
    # ActiveRecord exception, which is a 500 in any host that rescues ChangeRequests::Error.
    it "is the on_conflict mapping doing that, not the guard" do
      expect(ChangeRequests::Commands::Approve.conflict_mapping)
        .to eq(error_class: ChangeRequests::NotApprovable, reason: :already_decided)
      expect(ChangeRequests::NotApprovable.ancestors).to include(ChangeRequests::Error)
    end

    it "links the surviving approval to the quorum exactly once" do
      ChangeRequests::Testing.in_parallel(2) do
        ChangeRequests::Commands::Approve.call(request: reload, actor: actor)
      end

      expect(ChangeRequests::ApprovalQuorum.count).to eq(1)
    end
  end

  # 3. Approve and unapprove at once. Either order is legitimate; what must not happen is a status
  # that disagrees with the rows.
  describe "approve and unapprove at once" do
    let(:first) { approver("Ada") }
    let(:second) { approver("Ben") }

    before { ChangeRequests::Commands::Approve.call(request: change_request, actor: first) }

    it "leaves a final state consistent with the surviving approval count" do
      ChangeRequests::Testing.in_parallel(2) do |i|
        if i.zero?
          ChangeRequests::Commands::Unapprove.call(request: reload, actor: first)
        else
          ChangeRequests::Commands::Approve.call(request: reload, actor: second)
        end
      end

      request = reload
      satisfied = request.approvals.count >= request.stages.sole.quorums.sole.threshold

      expect(request.status).to eq(satisfied ? "approved" : "pending")
    end

    it "never leaves the stage closed on fewer approvals than its threshold" do
      ChangeRequests::Testing.in_parallel(2) do |i|
        if i.zero?
          ChangeRequests::Commands::Unapprove.call(request: reload, actor: first)
        else
          ChangeRequests::Commands::Approve.call(request: reload, actor: second)
        end
      end

      request = reload

      next unless request.stages.sole.status == "closed"

      expect(request.approvals.count).to be >= request.stages.sole.quorums.sole.threshold
    end
  end

  # The teeth. Rather than removing the lock and asserting the race breaks - which depends on the
  # scheduler and can pass by luck - these ask the question `with_lock` exists to answer: were two
  # commands ever inside the body at the same time? Both directions are deterministic, and neither
  # uses a mock, because rspec-mocks is not thread-safe and these run on real threads.
  describe "what with_lock is actually doing" do
    let(:actors) { [approver("Ada"), approver("Ben")] }

    before { actors }

    def race(command_class, overlap)
      ChangeRequests::Testing.in_parallel(2) do |i|
        command_class.new(request: reload, actor: actors[i], overlap: overlap).call
      end
    end

    it "serialises the command bodies, so no two are ever inside at once" do
      overlap = Overlap.new

      race(TimedApprove, overlap)

      expect(overlap.count).to eq(2)
      expect(overlap).not_to be_any
    end

    # The same measurement with the lock taken away. The held-open body is what makes it
    # deterministic: two bodies each held for 50ms cannot avoid overlapping once nothing
    # serialises them.
    #
    # Overlap is the claim, and deliberately not what the overlap then costs. Whether an unlocked
    # race ends in two stage_satisfied events, a StaleRequest, or - with a lucky interleaving -
    # nothing at all, depends on the scheduler; asserting any one of those would be a spec that
    # fails the build on a slow morning. What the damage looks like is what the three race
    # descriptions above assert does *not* happen while the lock is there.
    it "overlaps the moment the lock is gone, which is what it was preventing" do
      overlap = Overlap.new

      race(UnlockedApprove, overlap)

      expect(overlap.count).to eq(2)
      expect(overlap).to be_any
    end
  end

  # 5. §8's second requirement: no row lock may be held across the target invocation. Measured
  # rather than asserted - a NOWAIT lock attempt while the target runs either succeeds or does not.
  describe "the row lock across T2 (§8)" do
    let(:executer) { Manager.create!(id: "mgr-1", name: "Olive", roles: %w(ops)) }

    # The request was materialised under the outer declaration, whose quorum wants two - the
    # rows are the frozen snapshot, so re-declaring a threshold of one would change nothing
    # (§6.12 point 4). Only the service needs redeclaring: dispatch reads it live.
    before do
      BlockingTarget.entered = Queue.new
      BlockingTarget.release = Queue.new

      ChangeRequests.operations["members.update_roles"].service = "BlockingTarget"

      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver("Ada"))
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver("Ben"))

      # Touched here, never first inside a thread: memoized helpers are not synchronised, and a
      # `let` that creates a row would create it on the worker's connection.
      executer
    end

    # True when the row can be locked right now. FOR UPDATE NOWAIT raises instead of waiting, so
    # this answers the question without a timeout and without a sleep.
    def lockable?
      ChangeRequests::Request.lock("FOR UPDATE NOWAIT").find(change_request.id)

      true
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::StatementInvalid
      false
    end

    # Runs the given runner class in its own thread and asks the question mid-T2.
    def lockable_while_target_runs?(runner)
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          runner.call(request: ChangeRequests::Request.find(change_request.id), actor: executer)
        end
      end

      await_target(worker)

      lockable?.tap do
        BlockingTarget.release << :go
        worker.join
      end
    end

    # Fails loudly rather than hanging: a worker refused before it reaches the target would
    # otherwise leave this blocked on a queue nobody will ever push to.
    def await_target(worker)
      return if BlockingTarget.entered.pop(timeout: 10)

      worker.kill

      fail "the target was never invoked - the runner raised before T2: #{worker.value.inspect}"
    end

    it "is released before the target is invoked, so another process can take the row" do
      expect(lockable_while_target_runs?(ChangeRequests::Execution::Runner)).to be(true)
    end

    it "is held when the three transactions are collapsed into one, which is the teeth" do
      expect(lockable_while_target_runs?(LockedRunner)).to be(false)
    end

    it "leaves the request executing while the target runs, which is what the UI shows" do
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ChangeRequests::Execution::Runner.call(
            request: ChangeRequests::Request.find(change_request.id), actor: executer
          )
        end
      end

      await_target(worker)

      expect(reload.status).to eq("executing")
      expect(reload.attempts.sole).to have_attributes(number: 1, outcome: nil)

      BlockingTarget.release << :go
      worker.join

      expect(reload.status).to eq("successful")
    end
  end

  # 6-8. §15.3's execution races. Every one asserts the same thing first - the target ran exactly
  # once - because that is the only claim that is deterministic and the only one that matters.
  describe "execution races (§8, §15.3)" do
    let(:executer) { Manager.create!(id: "mgr-1", name: "Olive", roles: %w(ops)) }

    before do
      CountingTarget.count = 0

      ChangeRequests.operations["members.update_roles"].service = "CountingTarget"

      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver("Ada"))
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver("Ben"))

      # Touched before any thread exists, like every other row here.
      executer
    end

    def execute_in_parallel(count = 2)
      ChangeRequests::Testing.in_parallel(count) do
        ChangeRequests::Commands::Execute.call(request: reload, actor: executer)
      end
    end

    def refusals(outcomes)
      outcomes.grep(ChangeRequests::Error)
    end

    # 6. Two processes executing the same approved request.
    describe "two processes executing the same approved request" do
      it "invokes the target exactly once" do
        execute_in_parallel

        expect(CountingTarget.count).to eq(1)
      end

      it "writes one attempt, not two - the claim is what the ceiling counts (§5.6)" do
        execute_in_parallel

        expect(reload.attempts.count).to eq(1)
        expect(reload.status).to eq("successful")
      end

      # Exactly one loser, refused. *Which* refusal depends on how far the winner got before the
      # loser took the lock - mid-flight is :executing, finished is :already_finalized - and
      # asserting one of them would be a spec that fails the build on a slow morning (Q50).
      it "refuses exactly one of them, and tells it something true" do
        outcomes = execute_in_parallel

        expect(refusals(outcomes).size).to eq(1)
        expect(refusals(outcomes).first).to be_a(ChangeRequests::NotExecutable)
        expect(refusals(outcomes).first.reason).to be_in(%i(executing already_finalized))
      end

      it "emits one execution_started, so the timeline does not claim two runs" do
        execute_in_parallel

        expect(reload.events.where(kind: "execution_started").count).to eq(1)
      end
    end

    # 7. A retry racing the attempt ceiling. Its own request and its own operation: max_attempts
    # is readonly after create, so a ceiling above the default has to be declared before the row
    # exists - which is how a host sets one anyway.
    describe "a retry racing the attempt ceiling" do
      let(:retryable) do
        ChangeRequests.operations.define("orders.pay") do |op|
          op.version      = "2026-09-12"
          op.service      = "FailingTarget"
          op.max_attempts = 2
          op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
        end

        ChangeRequests::Commands::Create.call(operation_key: "orders.pay", requester: requester)
      end

      before do
        ChangeRequests::Commands::Approve.call(request: retryable, actor: approver("Cara"))

        spend_first_attempt!

        ChangeRequests.operations["orders.pay"].service = "CountingTarget"
      end

      def reload_retryable
        ChangeRequests::Request.find(retryable.id)
      end

      # Attempt one, spent on a target that raises: the request is left `failed` and retryable.
      # Not an expectation - this is setup, and it says so by failing with its own message.
      def spend_first_attempt!
        ChangeRequests::Commands::Execute.call(request: reload_retryable, actor: executer)

        fail "FailingTarget did not raise, so attempt one was not spent"
      rescue ChangeRequests::TargetFailed
        nil
      end

      def retry_in_parallel
        ChangeRequests::Testing.in_parallel(2) do
          ChangeRequests::Commands::Execute.call(request: reload_retryable, actor: executer)
        end
      end

      it "never exceeds max_attempts, whichever thread claims the last one (§8)" do
        retry_in_parallel

        expect(reload_retryable.attempts.count).to eq(2)
        expect(reload_retryable.attempts.count).to eq(reload_retryable.max_attempts)
      end

      it "invokes the target exactly once more" do
        retry_in_parallel

        expect(CountingTarget.count).to eq(1)
      end

      it "refuses the loser, the ceiling leaving room for only one of them" do
        outcomes = retry_in_parallel

        expect(refusals(outcomes).size).to eq(1)
        expect(reload_retryable.status).to eq("successful")
      end

      it "refuses both once the ceiling is spent, invoking nothing further" do
        retry_in_parallel

        outcomes = retry_in_parallel

        expect(refusals(outcomes).size).to eq(2)
        expect(CountingTarget.count).to eq(1)
      end
    end

    # 8. Execute racing Cancel. The invariant is that a canceled request never carries a committed
    # side effect, and a successful one never follows a committed cancellation.
    describe "execute racing cancel" do
      def race_cancel
        ChangeRequests::Testing.in_parallel(2) do |index|
          if index.zero?
            ChangeRequests::Commands::Execute.call(request: reload, actor: executer)
          else
            ChangeRequests::Commands::Cancel.call(request: reload, actor: requester,
                                                  reason: "no longer needed")
          end
        end
      end

      it "ends in one of the two outcomes and never a mixture of both" do
        race_cancel

        expect(reload.status).to be_in(%w(successful canceled))
      end

      it "leaves no side effect behind a cancellation, and no cancellation after one" do
        race_cancel

        if reload.canceled?
          expect(CountingTarget.count).to eq(0)
          expect(reload.attempts).to be_empty
        else
          expect(CountingTarget.count).to eq(1)
          expect(reload.events.where(kind: "canceled")).to be_empty
        end
      end

      it "refuses exactly one of the two, whichever lost" do
        outcomes = race_cancel

        expect(refusals(outcomes).size).to eq(1)
      end
    end
  end
end
