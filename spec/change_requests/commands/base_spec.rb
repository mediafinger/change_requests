# frozen_string_literal: true

require "rails_helper"

# Stand-ins for the real commands until M1b-4 … M1b-10 land.
module CommandProbes
  class Noop < ChangeRequests::Commands::Base
    def perform
      request
    end
  end

  class Emitting < ChangeRequests::Commands::Base
    def perform
      emit(:commented, body: options[:body], metadata: options.fetch(:metadata, {}))
    end
  end

  class Locked < ChangeRequests::Commands::Base
    def perform
      options.fetch(:observer).call(request)
    end
  end

  # Two approvals by the same actor on the same stage hit the unique index.
  class Duplicating < ChangeRequests::Commands::Base
    on_conflict ChangeRequests::NotApprovable, reason: :already_decided

    def perform
      2.times { options.fetch(:build).call }
    end
  end

  class DuplicatingUnmapped < ChangeRequests::Commands::Base
    def perform
      2.times { options.fetch(:build).call }
    end
  end

  class Stale < ChangeRequests::Commands::Base
    def perform
      options.fetch(:stale).update!(current_stage_position: 2)
    end
  end
end

RSpec.describe ChangeRequests::Commands::Base do
  subject(:command) { CommandProbes::Noop.new(request: change_request, actor: actor) }

  let(:actor) { Admin.create!(name: "Ada") }
  let(:change_request) { build_request }

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "Members::UpdateRoles"
    end
  end

  describe ".call" do
    it "builds an instance and runs it" do
      expect(CommandProbes::Noop.call(request: change_request, actor: actor)).to equal(change_request)
    end

    # Thresholds, permissions and quorum structure come from the operation. A caller-supplied
    # permission set is unverifiable by the gem and untestable by the host (§7).
    it "takes an actor, never a permission set" do
      expect(described_class.instance_method(:initialize).parameters)
        .to contain_exactly(%i(keyreq request), %i(key actor), %i(keyrest options))
    end

    it "keeps any further command options" do
      command = CommandProbes::Noop.new(request: change_request, actor: actor, reason: "Wrong member")

      expect(command.options).to eq(reason: "Wrong member")
    end

    it "refuses a command that forgot to implement perform" do
      expect { described_class.call(request: change_request, actor: actor) }
        .to raise_error(NotImplementedError, /Base.*perform/)
    end
  end

  describe "the lock" do
    it "runs the body inside a transaction" do
      open = nil
      CommandProbes::Locked.call(request: change_request, actor: actor,
                                 observer: ->(_r) { open = ActiveRecord::Base.connection.open_transactions })

      expect(open).to be > 1 # the suite's own wrapping transaction is the first
    end

    it "reads the row it locked, so the command sees committed state" do
      change_request.update!(status: "approved")
      seen = nil

      CommandProbes::Locked.call(request: change_request, actor: actor,
                                 observer: ->(request) { seen = request.status })

      expect(seen).to eq("approved")
    end

    # Rails refuses to lock a dirty record rather than discarding the assignment, which is the
    # behaviour worth having: a caller cannot lose a change it thought it was making.
    it "refuses a request carrying unsaved changes" do
      change_request.status = "approved"

      expect { CommandProbes::Noop.call(request: change_request, actor: actor) }
        .to raise_error(RuntimeError, /unpersisted changes/)
    end
  end

  describe "#emit" do
    subject(:event) do
      CommandProbes::Emitting.call(request: change_request, actor: actor, body: "Checked with HR",
                                   metadata: { stage: "approval" })
    end

    it "writes one event on the request" do
      expect { event }.to change { change_request.events.count }.by(1)
    end

    it "records the kind as a string" do
      expect(event.kind).to eq("commented")
    end

    it "carries the body and the metadata it was given" do
      expect(event.body).to eq("Checked with HR")
      expect(event.metadata).to eq("stage" => "approval")
    end

    it "defaults the metadata to an empty object rather than null" do
      event = CommandProbes::Emitting.call(request: change_request, actor: actor)

      expect(event.metadata).to eq({})
      expect(event.body).to be_nil
    end

    it "stamps occurred_at, so the timeline orders itself" do
      expect(event.occurred_at).to be_within(5.seconds).of(Time.current)
    end

    describe "the actor triple" do
      it "snapshots the acting actor, label included (§5.5)" do
        expect(event.actor).to eq(type: "Admin", id: actor.id.to_s, label: "Ada (admin)")
      end

      # Expiry, the reaper and undeclared-operation cancellation have no actor. The sentinel keeps
      # the triple not-null so no presenter or export branches on nil (§5.5, §19.15).
      it "falls back to the System sentinel when the command has no actor" do
        event = CommandProbes::Emitting.call(request: change_request, actor: nil)

        expect(event.actor).to eq(ChangeRequests::SYSTEM_ACTOR)
        expect(event).to be_system_actor
      end

      it "refuses an actor whose class is not registered (§9.1)" do
        expect { CommandProbes::Emitting.call(request: change_request, actor: Object.new) }
          .to raise_error(ChangeRequests::UnknownActorType)
      end
    end

    describe "operation_version" do
      # Deliberately not the same field as change_requests.operation_version: the request holds the
      # version it was created under, the event the version in force when this transition happened.
      # They diverge whenever a declaration changes during a request's life (§5.5).
      it "is read live from the declaration, not copied from the request" do
        expect(change_request.operation_version).to eq("2026-09-10")
        expect(event.operation_version).to eq("2026-09-12")
      end

      it "follows a declaration edited mid-flight" do
        ChangeRequests.operations["members.update_roles"].version = "2026-10-01"

        expect(event.operation_version).to eq("2026-10-01")
      end

      # The Comment and operation_undeclared cases: the only events ever written with no live
      # declaration record the version whose disappearance they are reporting (§5.11).
      it "falls back to the request's creation-time version when the operation is gone" do
        ChangeRequests.operations.clear

        expect(event.operation_version).to eq("2026-09-10")
      end
    end
  end

  describe "error mapping" do
    def build_duplicate_approval
      stage = build_stage(change_request)

      lambda do
        stage.approvals.create!(change_request: change_request, approver: actor,
                                decision: "approved", decided_at: Time.current)
      end
    end

    # A race the gem can lose, and it must not surface as a 500 (§15.3).
    it "maps a unique-index conflict to the command's own TransitionError" do
      build = build_duplicate_approval

      expect { CommandProbes::Duplicating.call(request: change_request, actor: actor, build: build) }
        .to raise_error(ChangeRequests::NotApprovable) { |error|
          expect(error.reason).to eq(:already_decided)
          expect(error.request).to eq(change_request)
        }
    end

    # Only a command that actually races an index declares a mapping. An undeclared conflict is a
    # bug to see, not a refusal to dress it up as.
    it "re-raises a conflict the command did not declare a mapping for" do
      build = build_duplicate_approval

      expect { CommandProbes::DuplicatingUnmapped.call(request: change_request, actor: actor, build:) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "maps a lost optimistic lock to StaleRequest" do
      stale = ChangeRequests::Request.find(change_request.id)
      change_request.update!(current_stage_position: 3)

      expect { CommandProbes::Stale.call(request: change_request, actor: actor, stale: stale) }
        .to raise_error(ChangeRequests::StaleRequest, /#{change_request.id}/)
    end
  end

  describe "helpers" do
    it "resolves the operation live, never from the columns on the row (§6.12)" do
      expect(command.operation).to equal(ChangeRequests.operations["members.update_roles"])
    end

    it "returns nil for an operation that is no longer declared" do
      ChangeRequests.operations.clear

      expect(command.operation).to be_nil
    end

    it "reaches the configuration without every command naming the module" do
      expect(command.config).to equal(ChangeRequests.config)
    end
  end
end

# §5.5: "Every event is written through one path (emit in Commands::Base), so the column is
# populated in a single place." A runtime spec can only prove it for the paths it exercises; this
# proves it for the code.
