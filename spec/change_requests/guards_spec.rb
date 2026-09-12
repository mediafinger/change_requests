# frozen_string_literal: true

require "rails_helper"

# What a per-guard spec structurally cannot see (§15.2).
#
# Each guard's own file asserts its branches in isolation, which is why they all pass while
# disagreeing with each other. The branch orders were chosen to line up - `Reject` mirrors `Approve`
# so "not your turn yet" reads the same wherever a person meets it - and nothing failed when they
# drifted. This is the spec that fails.
#
# It is deliberately narrow: the status axis is written out cell by cell, because that is the axis
# every guard has an opinion about; the actor-role axis is asserted as rules, because the per-guard
# files already cover roles and a 400-cell table tends to get regenerated from the code it checks.
# The table itself, hoisted out of the example group so it is available when examples are defined -
# the same shape as GuardProbes and CommandProbes elsewhere in the suite.
module GuardMatrix
  ALL = %i(Approve Unapprove Reject Cancel Comment Execute Expire).freeze

  # One row per status. `-` means the guard permits it.
  #
  # Columns, in order: Approve, Unapprove, Reject, Cancel, Comment, Execute, Expire.
  BY_STATUS = {
    "pending" => %i(allowed not_the_approver allowed allowed allowed
                    not_approved not_expired),
    "approved" => %i(not_pending not_pending not_pending allowed allowed
                     allowed not_expired),
    "executing" => %i(not_pending not_pending not_pending executing allowed
                      executing not_expirable),
    "failed" => %i(not_pending not_pending not_pending allowed allowed
                   allowed not_expirable),
    "successful" => %i(already_finalized already_finalized already_finalized already_finalized allowed
                       already_finalized already_finalized),
    "rejected" => %i(already_finalized already_finalized already_finalized already_finalized allowed
                     already_finalized already_finalized),
    "canceled" => %i(already_finalized already_finalized already_finalized already_finalized allowed
                     already_finalized already_finalized),
    "expired" => %i(already_finalized already_finalized already_finalized already_finalized allowed
                    already_finalized already_finalized),
  }.freeze
end

RSpec.describe ChangeRequests::Guards do
  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:approver) { Admin.create!(name: "Ada", roles: %w(member_admin)) }

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "Members::UpdateRoles"
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
    end
  end

  def build(status)
    change_request = ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                                           requester: requester)
    change_request.update_columns(status: status)

    change_request.reload
  end

  # Expire is system-only, so its cell is read with no actor; every other guard is read as an
  # eligible approver who has not yet decided.
  def reason_for(guard_name, change_request, actor: approver)
    guard = described_class.const_get(guard_name)
                           .new(request: change_request, actor: guard_name == :Expire ? nil : actor)

    guard.reason || :allowed
  end

  it "covers every status the model declares, so a new one cannot slip past the table" do
    expect(GuardMatrix::BY_STATUS.keys).to match_array(ChangeRequests::Request::STATUSES)
  end

  it "covers every guard, so a new one cannot ship without a row in it" do
    expect(GuardMatrix::ALL + [:Base]).to match_array(described_class.constants)
  end

  GuardMatrix::BY_STATUS.each do |status, expected|
    GuardMatrix::ALL.zip(expected).each do |guard_name, reason|
      it "#{guard_name} answers #{reason} for a #{status} request" do
        expect(reason_for(guard_name, build(status))).to eq(reason)
      end
    end
  end

  # The rules the status table is the evidence for. Each is an invariant no single guard's spec can
  # state, because each is about two guards agreeing.
  describe "the invariants across guards" do
    # Q48. Before this, Approve, Unapprove and Reject said :not_pending for a finished request while
    # Cancel, Execute and Expire said :already_finalized - so a host rescuing AlreadyFinalized to
    # mean "this is over" caught three commands and missed three.
    it "answers a finished request with one reason, whichever guard met it" do
      answers = ChangeRequests::Request::FINAL_STATUSES.flat_map do |status|
        change_request = build(status)

        (GuardMatrix::ALL - [:Comment]).map { |name| reason_for(name, change_request) }
      end

      expect(answers.uniq).to eq([:already_finalized])
    end

    it "raises AlreadyFinalized for it, whichever guard met it (Q29)" do
      change_request = build("canceled")

      classes = (GuardMatrix::ALL - [:Comment]).map do |name|
        described_class.const_get(name)
                       .new(request: change_request, actor: name == :Expire ? nil : approver)
                       .check!
      rescue ChangeRequests::Error => e
        e.class
      end

      expect(classes.uniq).to eq([ChangeRequests::AlreadyFinalized])
    end

    # §5.5: post-mortem notes on a finished request are the point of an audit trail, and a comment
    # writes no request column so the terminal-state guard is never in its way.
    it "leaves Comment the only guard open on a request that is over" do
      open_guards = ChangeRequests::Request::FINAL_STATUSES.flat_map do |status|
        change_request = build(status)

        GuardMatrix::ALL.select { |name| reason_for(name, change_request) == :allowed }
      end

      expect(open_guards.uniq).to eq([:Comment])
    end

    # §6.9's stage-three director. Approve and Reject both have an opinion; they must word it
    # identically, because a person meets the same situation through both buttons.
    it "says :stage_not_current, in every guard that distinguishes it" do
      change_request = build("pending")
      sign_off = change_request.stages.create!(position: 2, name: "sign_off")
      sign_off.quorums.create!(position: 1, threshold: 1).permissions.create!(permission: "director")
      director = Admin.create!(name: "Dora", roles: %w(director))

      answers = %i(Approve Reject).map { |name| reason_for(name, change_request, actor: director) }

      expect(answers.uniq).to eq([:stage_not_current])
    end

    # §7.2's preamble: for Cancel and Comment "eligible approver" is not restricted to the current
    # stage, because both are judgements about the request as a whole.
    it "lets the same director cancel or comment, where eligibility spans every stage" do
      change_request = build("pending")
      sign_off = change_request.stages.create!(position: 2, name: "sign_off")
      sign_off.quorums.create!(position: 1, threshold: 1).permissions.create!(permission: "director")
      director = Admin.create!(name: "Dora", roles: %w(director))

      answers = %i(Cancel Comment).map { |name| reason_for(name, change_request, actor: director) }

      expect(answers.uniq).to eq([:allowed])
    end

    # The registry is the allowlist, and no guard may quietly let an unregistered class through -
    # but each has to be asked at a status where it gets as far as reading the actor at all.
    # Execute answers about the request first: on a `pending` request it returns :not_approved
    # without ever looking, which is correct and is why this is not one flat assertion.
    {
      Approve: "pending", Unapprove: "pending", Reject: "pending",
      Cancel: "pending", Comment: "pending", Execute: "approved"
    }.each do |guard_name, status|
      it "refuses an unregistered actor class from #{guard_name}" do
        expect { reason_for(guard_name, build(status), actor: Object.new) }
          .to raise_error(ChangeRequests::UnknownActorType)
      end
    end

    # Expire is the exception, and deliberately: it takes no actor, and an actor being supplied at
    # all is its refusal.
    it "needs no actor for Expire, which refuses one on sight" do
      guard = ChangeRequests::Guards::Expire.new(request: build("pending"), actor: Object.new)

      expect(guard.reason).to eq(:not_system)
    end

    # §5.11 as amended by I8, run here across the whole set rather than one guard at a time.
    it "refuses an undeclared operation everywhere but Comment" do
      change_request = build("pending")
      ChangeRequests.operations.clear

      refusing = GuardMatrix::ALL.select { |name| reason_for(name, change_request) == :operation_undeclared }

      expect(refusing).to match_array(GuardMatrix::ALL - [:Comment])
    end

    # Every reason any guard can produce has to be in the shared vocabulary, and M1b-13's locale
    # spec then guarantees each has words. This is the link between the two.
    it "produces only reasons the vocabulary declares" do
      produced = GuardMatrix::BY_STATUS.keys.flat_map do |status|
        change_request = build(status)

        GuardMatrix::ALL.map { |name| reason_for(name, change_request) }
      end.uniq - [:allowed]

      expect(produced - ChangeRequests::Guards::Base::REASONS).to be_empty
    end
  end
end
