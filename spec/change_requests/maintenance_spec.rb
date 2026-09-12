# frozen_string_literal: true

require "rails_helper"

module MaintenanceProbes
  class Roles
    def self.call(**)
      :done
    end
  end
end

RSpec.describe ChangeRequests::Maintenance do
  let(:requester) { User.create!(name: "Alice", email: "alice@example.com") }
  let(:executer) { Manager.create!(id: "mgr-1", name: "Olive", roles: %w(ops)) }

  def declare(key = "members.update_roles", expires_in: nil)
    ChangeRequests.operations.define(key) do |op|
      op.version    = "2026-09-12"
      op.service    = "MaintenanceProbes::Roles"
      op.expires_in = expires_in
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
    end
  end

  def create(key = "members.update_roles")
    ChangeRequests::Commands::Create.call(operation_key: key, requester: requester)
  end

  def approve!(request)
    ChangeRequests::Commands::Approve.call(
      request: request, actor: Admin.create!(name: "Amy#{request.id[0, 4]}", roles: %w(member_admin))
    )
  end

  def system_event(request, kind)
    request.reload.events.find_by!(kind: kind)
  end

  describe ".expire_stale!" do
    before { declare(expires_in: 60) }

    it "expires a pending request whose deadline has passed, and reports the count" do
      request = create
      request.update_columns(expires_at: 1.minute.ago)

      expect(described_class.expire_stale!).to eq(1)
      expect(request.reload.status).to eq("expired")
    end

    it "expires an approved one too (§8)" do
      request = create
      approve!(request)
      request.update_columns(expires_at: 1.minute.ago)

      expect { described_class.expire_stale! }
        .to change { request.reload.status }.from("approved").to("expired")
    end

    it "leaves a request whose deadline has not arrived" do
      request = create
      request.update_columns(expires_at: 1.hour.from_now)

      expect(described_class.expire_stale!).to eq(0)
      expect(request.reload.status).to eq("pending")
    end

    it "leaves a request that never expires, a null expires_at being the default (§5.1)" do
      declare(expires_in: nil)
      request = create

      expect(request.expires_at).to be_nil
      expect(described_class.expire_stale!).to eq(0)
      expect(request.reload.status).to eq("pending")
    end

    it "attributes the expiry to the System sentinel (§19.15)" do
      request = create
      request.update_columns(expires_at: 1.minute.ago)

      described_class.expire_stale!

      expect(system_event(request, "expired").actor)
        .to eq(ChangeRequests::SYSTEM_ACTOR)
    end
  end

  describe ".reap_stuck_executions!" do
    subject(:reap) { described_class.reap_stuck_executions! }

    let(:stuck) do
      request = create
      approve!(request)
      request.update!(status: "executing")
      request.attempts.create!(number: 1, started_at: 2.hours.ago, executer: executer)

      request
    end

    before { declare }

    it "fails a claimed request nobody ever settled" do
      expect { reap }.to change { stuck.reload.status }.from("executing").to("failed")
    end

    it "reports how many rows it moved" do
      stuck

      expect(reap).to eq(1)
    end

    it "finds nothing the second time, the row no longer being executing" do
      stuck
      reap

      expect(described_class.reap_stuck_executions!).to eq(0)
    end

    it "marks the attempt abandoned rather than failed - nobody saw it fail (§5.6)" do
      stuck
      reap

      expect(stuck.reload.attempts.sole)
        .to have_attributes(outcome: "abandoned", number: 1)
      expect(stuck.attempts.sole.finished_at).to be_present
    end

    it "emits reaped carrying which attempt and how long it was stuck (Q6)" do
      stuck
      reap
      event = system_event(stuck, "reaped")

      expect(event.metadata["attempt"]).to eq(1)
      expect(event.metadata["stuck_for"]).to be_within(60).of(2.hours.to_i)
      expect(event.actor).to eq(ChangeRequests::SYSTEM_ACTOR)
    end

    it "leaves an execution that started recently" do
      request = create
      approve!(request)
      request.update!(status: "executing")
      request.attempts.create!(number: 1, started_at: 1.minute.ago, executer: executer)

      expect(reap).to eq(0)
      expect(request.reload.status).to eq("executing")
    end

    it "takes the threshold from the caller" do
      request = create
      approve!(request)
      request.update!(status: "executing")
      request.attempts.create!(number: 1, started_at: 5.minutes.ago, executer: executer)

      expect(described_class.reap_stuck_executions!(older_than: 60)).to eq(1)
      expect(request.reload.status).to eq("failed")
    end

    it "leaves an attempt that finished, however long ago it started" do
      request = create
      approve!(request)
      request.update!(status: "executing")
      request.attempts.create!(number: 1, started_at: 2.hours.ago, finished_at: 2.hours.ago,
                               outcome: "succeeded", executer: executer)

      expect(reap).to eq(0)
    end

    it "leaves a request that is not executing at all" do
      request = create
      request.attempts.create!(number: 1, started_at: 2.hours.ago, executer: executer)

      expect(reap).to eq(0)
      expect(request.reload.status).to eq("pending")
    end

    # §5.11 as M3b-2 amends it: Cancel refuses an `executing` request (Q28), so a claim that died
    # just as its declaration vanished would otherwise be reachable by no sweeper at all.
    it "writes off a stuck execution whose declaration vanished" do
      stuck
      ChangeRequests.operations.clear

      expect(reap).to eq(1)
      expect(stuck.reload.status).to eq("failed")
    end

    # `failed` is not final, so the approval stands and the retry ceiling decides the rest (§8).
    it "leaves the request retryable within its ceiling" do
      stuck.update_columns(max_attempts: 2)
      reap

      expect(stuck.reload).to be_retryable
    end
  end

  describe ".cancel_undeclared!" do
    subject(:sweep) { described_class.cancel_undeclared! }

    before { declare }

    it "cancels a request whose declaration vanished, and reports the count" do
      request = create
      ChangeRequests.operations.clear

      expect(sweep).to eq(1)
      expect(request.reload.status).to eq("canceled")
    end

    it "leaves a request whose operation is still declared" do
      create

      expect(sweep).to eq(0)
    end

    # The whole reason this is a rake task and not an automatic sweeper (§5.11): a missing
    # declaration is as likely to be a deploy accident as a deliberate removal.
    it "leaves a request whose operation reappeared before the sweep ran" do
      request = create
      ChangeRequests.operations.clear
      declare

      expect(sweep).to eq(0)
      expect(request.reload.status).to eq("pending")
    end

    it "cancels only the undeclared ones, leaving the rest alone" do
      declare("orders.pay")
      stranded = create("orders.pay")
      live = create
      ChangeRequests.operations.clear
      declare

      expect(sweep).to eq(1)
      expect(stranded.reload.status).to eq("canceled")
      expect(live.reload.status).to eq("pending")
    end

    it "leaves a request that is already final" do
      request = create
      ChangeRequests::Commands::Cancel.call(request: request, actor: requester, reason: "changed my mind")
      ChangeRequests.operations.clear

      expect(sweep).to eq(0)
    end

    # Guards::Cancel refuses a request mid-flight, undeclared or not: the reaper clears those.
    it "leaves a request whose target is executing" do
      request = create
      approve!(request)
      request.update!(status: "executing")
      ChangeRequests.operations.clear

      expect(sweep).to eq(0)
      expect(request.reload.status).to eq("executing")
    end

    describe "the event it emits (Q11, §5.11)" do
      subject(:event) do
        request = create
        ChangeRequests.operations.clear
        described_class.cancel_undeclared!

        system_event(request, "operation_undeclared")
      end

      it "is operation_undeclared, not canceled - nobody decided this" do
        expect(event.kind).to eq("operation_undeclared")
      end

      it "carries the System sentinel" do
        expect(event.actor).to eq(ChangeRequests::SYSTEM_ACTOR)
      end

      it "records the key and the creation-time version whose disappearance it reports (§5.5)" do
        expect(event.metadata).to include("operation_key" => "members.update_roles",
                                          "operation_version" => "2026-09-12")
      end

      it "records what it was cancelled out of, as Cancel does" do
        expect(event.metadata).to include("status" => "pending")
      end

      it "stamps the creation-time version on the column too, there being no live one to read" do
        expect(event.operation_version).to eq("2026-09-12")
      end

      it "carries a translatable reason rather than a hardcoded sentence (§5.11)" do
        expect(event.body).to eq("This operation is no longer declared, so the request could never run.")
      end

      it "reads a host's translation when there is one" do
        request = create
        ChangeRequests.operations.clear
        with_translations(ChangeRequests::Commands::CancelUndeclared::REASON_KEY => "Gone.")

        described_class.cancel_undeclared!

        expect(system_event(request, "operation_undeclared").body).to eq("Gone.")
      end
    end

    # Q11's other half: a person cancelling the same row emits `canceled`, with their own reason.
    it "is not what an ordinary actor cancelling the same request emits" do
      request = create
      ChangeRequests.operations.clear

      ChangeRequests::Commands::Cancel.call(request: request, actor: requester, reason: "tidying up")

      expect(request.reload.events.map(&:kind)).to include("canceled")
      expect(request.events.map(&:kind)).not_to include("operation_undeclared")
    end
  end

  # M9b: a cooldown window has to exist before a stage can be due.
  it "does not sweep due stages yet" do
    expect(described_class).not_to respond_to(:close_due_stages!)
  end
end
