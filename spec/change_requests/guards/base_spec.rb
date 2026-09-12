# frozen_string_literal: true

require "rails_helper"

# Stand-ins for the real guards until M1b-2 … M1b-11 land. They exist so the shared example and the
# §5.11 exemption have something to run against now, rather than being asserted for the first time
# by the ticket that depends on them.
module GuardProbes
  class Ordinary < ChangeRequests::Guards::Base
    refuses_with ChangeRequests::NotApprovable
  end

  class Exempt < ChangeRequests::Guards::Base
    refuses_with ChangeRequests::NotAuthorized
    exempt_from_undeclared_operation!
  end

  class Fussy < ChangeRequests::Guards::Base
    refuses_with ChangeRequests::NotApprovable

    def refusal
      request.pending? ? nil : :not_pending
    end
  end

  class Undeclared < ChangeRequests::Guards::Base; end
end

RSpec.describe ChangeRequests::Guards::Base do
  subject(:guard) { GuardProbes::Ordinary.new(request: change_request, actor: actor) }

  let(:actor) { Admin.create!(name: "Grace") }
  let(:change_request) { build_request }

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-11"
      op.service = "Members::UpdateRoles"
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
    end
  end

  describe "the interface every guard answers (§7)" do
    it "takes the request and the acting actor" do
      expect(guard.request).to equal(change_request)
      expect(guard.actor).to equal(actor)
    end

    # Cancel and Reject take `reason:`, Execute takes `override:`. The guard's own `reason` is the
    # refusal, so a command option of the same name stays in `options`.
    it "keeps any further command options" do
      guard = GuardProbes::Ordinary.new(request: change_request, actor: actor,
                                        reason: "No longer needed", override: true)

      expect(guard.options).to eq(reason: "No longer needed", override: true)
    end

    it "allows when nothing refuses" do
      expect(guard).to be_allowed
      expect(guard.reason).to be_nil
    end

    it "returns the request from check!, so a command can chain on it" do
      expect(guard.check!).to equal(change_request)
    end

    it "raises the guard's own error when it refuses" do
      change_request.update!(status: "approved")
      guard = GuardProbes::Fussy.new(request: change_request, actor: actor)

      expect { guard.check! }.to raise_error(ChangeRequests::NotApprovable) { |error|
        expect(error.reason).to eq(:not_pending)
      }
    end
  end

  describe "the undeclared-operation refusal (§5.11)" do
    it "refuses before the subclass is consulted, so no guard has to repeat it" do
      ChangeRequests.operations.clear

      expect(GuardProbes::Ordinary.new(request: change_request, actor: actor).reason)
        .to eq(:operation_undeclared)
    end

    it "consults the subclass while the operation is declared" do
      change_request.update!(status: "approved")

      expect(GuardProbes::Fussy.new(request: change_request, actor: actor).reason).to eq(:not_pending)
    end

    it "exempts a guard that asked to be exempt (I8)" do
      ChangeRequests.operations.clear

      expect(GuardProbes::Exempt.new(request: change_request, actor: actor)).to be_allowed
    end

    it "does not leak the exemption to its siblings" do
      expect(GuardProbes::Ordinary.exempt_from_undeclared_operation).to be(false)
      expect(GuardProbes::Exempt.exempt_from_undeclared_operation).to be(true)
    end
  end

  describe ".refuses_with" do
    it "names the error check! raises" do
      expect(GuardProbes::Ordinary.error_class).to eq(ChangeRequests::NotApprovable)
    end

    # NotAuthorized for Create, Comment and Expire; the TransitionError family for the rest. Deriving
    # it from the class name would get all three of those wrong.
    it "is declared, not derived from the guard's name" do
      expect(GuardProbes::Exempt.error_class).to eq(ChangeRequests::NotAuthorized)
    end

    it "fails loudly when a guard forgot to declare one" do
      ChangeRequests.operations.clear
      guard = GuardProbes::Undeclared.new(request: change_request, actor: actor)

      expect { guard.check! }
        .to raise_error(ChangeRequests::ConfigurationError, /GuardProbes::Undeclared.*refuses_with/)
    end
  end

  describe "helpers" do
    it "reaches the configuration without every guard naming the module" do
      expect(guard.config).to equal(ChangeRequests.config)
    end

    it "resolves the operation live, never from the columns on the row (§6.12)" do
      expect(guard.operation).to equal(ChangeRequests.operations["members.update_roles"])
    end

    it "returns nil for an operation that is no longer declared" do
      ChangeRequests.operations.clear

      expect(guard.operation).to be_nil
    end

    it "reads the request's current stage" do
      stage = build_stage(change_request, position: 1)
      build_stage(change_request, position: 2, name: "sign_off")

      expect(guard.stage).to eq(stage)
    end

    it "has no stage before the workflow is materialised" do
      expect(guard.stage).to be_nil
    end

    describe "#actor_ref" do
      it "is the acting actor as the columns store it (§5.7)" do
        expect(guard.actor_ref).to eq(type: "Admin", id: actor.id.to_s, label: "Grace (admin)")
      end

      it "refuses an actor whose class is not registered, which is the allowlist working (§9.1)" do
        guard = GuardProbes::Ordinary.new(request: change_request, actor: Object.new)

        expect { guard.actor_ref }.to raise_error(ChangeRequests::UnknownActorType)
      end
    end

    describe "#same_person?" do
      let(:other_admin) { Admin.create!(name: "Ada") }

      it "matches an actor against the reference stored for them" do
        expect(guard.same_person?(guard.actor_ref, actor)).to be(true)
      end

      it "separates two records of the same class" do
        expect(guard.same_person?(guard.actor_ref, other_admin)).to be(false)
      end

      # (type, id) is airtight within one actor class and blind across them (§9.4).
      it "separates the same id held by two different classes" do
        user = User.create!(name: "Grace", email: "grace@example.com")

        expect(guard.same_person?({ type: "User", id: user.id.to_s }, actor)).to be(false)
      end

      it "is false when either side is missing" do
        expect(guard.same_person?(nil, actor)).to be(false)
        expect(guard.same_person?(guard.actor_ref, nil)).to be(false)
      end

      context "when config.actor_identity is set (§9.4)" do
        before { ChangeRequests.config.actor_identity = ->(person) { person.name } }

        it "counts two live actors of different classes as one person" do
          user = User.create!(name: "Grace", email: "grace@example.com")

          expect(guard.same_person?(user, actor)).to be(true)
        end

        it "still separates two people who happen to share a class" do
          expect(guard.same_person?(other_admin, actor)).to be(false)
        end

        # Only change_request_approvals carries approver_identity; nothing snapshots the requester's.
        it "falls back to (type, id) when one side is a stored reference with no identity" do
          user = User.create!(name: "Grace", email: "grace@example.com")

          expect(guard.same_person?({ type: "User", id: user.id.to_s }, actor)).to be(false)
        end

        it "uses a stored identity when the reference carries one" do
          expect(guard.same_person?({ type: "User", id: "999", identity: "Grace" }, actor)).to be(true)
        end
      end
    end
  end

  describe "the shared reason vocabulary" do
    it "is frozen, so a guard cannot append to it at runtime" do
      expect(described_class::REASONS).to be_frozen
    end

    it "holds only symbols, which is what TransitionError#reason promises hosts" do
      expect(described_class::REASONS).to all(be_a(Symbol))
    end

    it "has no duplicates" do
      expect(described_class::REASONS.uniq).to eq(described_class::REASONS)
    end

    it "carries the refusal that lives in the base class" do
      expect(described_class::REASONS).to include(:operation_undeclared)
    end
  end

  # The shared example every guard spec includes from M1b-2 onwards, proved here against both sides
  # of the §5.11 exemption.
  describe GuardProbes::Ordinary do
    subject(:guard) { described_class.new(request: change_request, actor: actor) }

    it_behaves_like "a change request guard"
  end

  describe GuardProbes::Exempt do
    subject(:guard) { described_class.new(request: change_request, actor: actor) }

    it_behaves_like "a change request guard"
  end
end
