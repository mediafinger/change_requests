# frozen_string_literal: true

# The targets `verify!` resolves. Real constants, because the whole point of the check is that a
# string in an initializer names something that exists and answers the method dispatch will call.
module VerifyProbes
  class Sound
    def self.call(**)
      :done
    end
  end

  class InstanceOnly
    def call(**)
      :done
    end
  end

  class Perform
    def self.perform(**)
      :done
    end
  end

  class Private
    class << self
      private

      def call(**)
        :done
      end
    end
  end

  class Positional
    def self.call(member_id)
      member_id
    end
  end
end

# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "ChangeRequests.operations.verify! (§6.12 point 6)" do
  subject(:operations) { ChangeRequests::Operations.new }

  def define(key = "members.update_roles", **overrides, &block)
    operations.define(key) do |op|
      op.version = overrides.fetch(:version, "2026-09-12")
      op.service = overrides.fetch(:service, "VerifyProbes::Sound")
      op.method_name = overrides[:method_name] if overrides.key?(:method_name)
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }

      block&.call(op)
    end
  end

  describe "a sound registry" do
    it "returns true rather than raising" do
      define

      expect(operations.verify!).to be(true)
    end

    it "verifies an empty registry, there being nothing to be wrong" do
      expect(operations.verify!).to be(true)
    end

    it "reports no problems" do
      define "a.first"
      define "b.second", method_name: :perform, service: "VerifyProbes::Perform"

      expect(operations.problems).to be_empty
    end
  end

  describe "the dispatch target (§6.12)" do
    it "refuses a service constant that does not resolve" do
      define(service: "Members::NoSuchThing")

      expect(operations.problems.join).to include("Members::NoSuchThing")
    end

    # §6.12: verification checks the singleton method dispatch will actually call, so an ordinary
    # `def self.call` target is validated against how it is invoked.
    it "accepts an ordinary def self.call target" do
      define(service: "VerifyProbes::Sound")

      expect(operations.problems).to be_empty
    end

    it "refuses a target that answers the method only as an instance method" do
      define(service: "VerifyProbes::InstanceOnly")

      expect(operations.problems.join).to match(/VerifyProbes::InstanceOnly.*\.call/)
    end

    it "refuses a target whose singleton method is private, dispatch using public_send" do
      define(service: "VerifyProbes::Private")

      expect(operations.problems.join).to include(".call")
    end

    it "checks the declared method_name, not :call" do
      define(service: "VerifyProbes::Perform", method_name: :perform)

      expect(operations.problems).to be_empty
    end

    # M3a-1: the contract is keyword arguments only, and that is knowable at boot rather than on
    # the first execution of a request someone has already approved (§6.12).
    it "refuses a target taking positional arguments, naming the contract" do
      define(service: "VerifyProbes::Positional")

      expect(operations.problems.join).to match(/takes positional arguments.*keyword arguments only/)
    end

    it "refuses a declared method_name the target does not answer" do
      define(service: "VerifyProbes::Sound", method_name: :perform)

      expect(operations.problems.join).to include(".perform")
    end

    # Regression: target_problems called `respond_to?(nil)`, which raises TypeError - so verify!
    # crashed on the one problem it exists to report.
    it "reports a method_name assigned away rather than raising TypeError" do
      define.method_name = nil

      expect(operations.problems.join).to include("op.method_name")
    end

    it "says nothing about the target when the method_name is gone, problems having said it" do
      define.method_name = nil

      expect(operations.problems.grep(/does not answer/)).to be_empty
    end

    # A service that is missing entirely is already reported by the completeness check; saying
    # "NilClass does not resolve" on top of it would be noise.
    it "says nothing about the target when no service is declared at all" do
      operation = define
      operation.service = nil

      expect(operations.problems.grep(/resolve|respond/)).to be_empty
    end
  end

  describe "one raised error listing every problem (Q4)" do
    it "names the operation each problem belongs to" do
      define("orders.refund", service: "Members::NoSuchThing")

      expect { operations.verify! }
        .to raise_error(ChangeRequests::ConfigurationError, /orders\.refund/)
    end

    it "raises once, listing four different problems rather than one per call" do
      define("orders.refund").version = nil
      define("orders.ship").service = nil
      define("orders.hold", service: "Members::NoSuchThing")
      define("orders.void", service: "VerifyProbes::InstanceOnly")

      expect { operations.verify! }.to raise_error(ChangeRequests::ConfigurationError) { |error|
        expect(error.message.lines.grep(/^- /).size).to eq(4)
      }
    end

    it "reports every operation, not only the first unsound one" do
      define("orders.refund", service: "Members::NoSuchThing")
      define("orders.ship", service: "Members::AlsoMissing")

      expect(operations.problems.size).to eq(2)
    end
  end

  describe "what Commands::Create refuses at runtime, re-checked at boot (Q19)" do
    it "refuses an operation with no service" do
      define.service = nil

      expect(operations.problems.join).to include("no service")
    end

    # The DSL refuses both of these at declaration, so a hand-built description is the only way
    # to reach the re-check - which is the point of re-checking: one call reports everything.
    it "refuses an operation with no approvals at all" do
      define.instance_variable_set(:@workflow, ChangeRequests::Workflow.new)

      expect(operations.problems.join).to include("no approvals")
    end

    it "re-checks the version, so one call reports everything (§5.10)" do
      define.version = nil

      expect(operations.problems.join).to include("version")
    end

    it "refuses a quorum whose threshold is not positive" do
      define.instance_variable_set(:@workflow, workflow_with_threshold(0))

      expect(operations.problems.join).to include("threshold")
    end

    def workflow_with_threshold(threshold)
      quorum = ChangeRequests::Workflow::Quorum.new(
        name: "owners", position: 1, threshold: threshold, permission_match: :any,
        permissions: [ChangeRequests::Workflow::Permission.new(permission: "owner", actor_type: nil)],
        eligible_actors: []
      )

      ChangeRequests::Workflow.new(
        [ChangeRequests::Workflow::Stage.new(name: "approval", position: 1,
                                             satisfied_by: :any_quorum, quorums: [quorum])]
      )
    end
  end
end
