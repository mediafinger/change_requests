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
end
