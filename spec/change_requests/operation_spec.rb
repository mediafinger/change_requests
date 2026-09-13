# frozen_string_literal: true

RSpec.describe ChangeRequests::Operation do
  subject(:operation) { described_class.new("members.update_roles") }

  describe "attributes" do
    it "keeps the key as a string, whatever it was declared as" do
      expect(described_class.new(:"members.update_roles").key).to eq("members.update_roles")
    end

    it "defaults the dispatch target's method to the documented :call (§6.12)" do
      expect(operation.method_name).to eq(:call)
    end

    it "symbolises a method name declared as a string" do
      operation.method_name = "perform"

      expect(operation.method_name).to eq(:perform)
    end

    it "starts with no workflow at all, so an operation must declare who approves it" do
      expect(operation.workflow).to be_empty
    end
  end

  describe "defaults resolved from the configuration" do
    # Lazily, not at declaration time: initializer order is the host's, and an operations file that
    # loads before the config file should still see the host's defaults.
    it "takes max_attempts from config.default_max_attempts" do
      ChangeRequests.config.default_max_attempts = 5

      expect(operation.max_attempts).to eq(5)
    end

    it "prefers an explicitly declared max_attempts" do
      ChangeRequests.config.default_max_attempts = 5
      operation.max_attempts = 2

      expect(operation.max_attempts).to eq(2)
    end

    it "takes expires_in from config.default_expires_in" do
      ChangeRequests.config.default_expires_in = 604_800

      expect(operation.expires_in).to eq(604_800)
    end

    # nil is a value here, not an absence: it means "this one never expires".
    it "lets an operation opt out of a host-wide expiry by declaring nil" do
      ChangeRequests.config.default_expires_in = 604_800
      operation.expires_in = nil

      expect(operation.expires_in).to be_nil
    end
  end

  describe "#validate!" do
    it "passes once the declaration is complete" do
      complete!

      expect(operation.validate!).to be(true)
    end

    it "refuses an operation with no version (§5.10)" do
      expect { operation.validate! }
        .to raise_error(ChangeRequests::ConfigurationError, /members\.update_roles.*version/m)
    end

    it "refuses a blank version, which snapshots onto every request as a NOT NULL column" do
      operation.version = "  "

      expect { operation.validate! }.to raise_error(ChangeRequests::ConfigurationError, /version/)
    end
  end

  # One implementation, three readers: validate! here, Commands::Create at creation and
  # Operations#verify! at boot, so none of them can disagree (§7.2 †, §6.12 point 6).
  describe "#problems" do
    it "is empty for a complete declaration" do
      complete!

      expect(operation.problems).to be_empty
    end

    it "reports a missing service, which nothing could ever execute" do
      complete!
      operation.service = nil

      expect(operation.problems.join).to include("no service")
    end

    it "reports an empty workflow, which no request could ever leave pending" do
      operation.version = "2026-09-11"
      operation.service = "Members::UpdateRoles"

      expect(operation.problems.join).to include("no approvals")
    end

    # `attr_writer :method_name` lets a host assign the documented :call default away. Dispatch
    # then has nothing to call, and the NOT NULL column would surface it as a RecordInvalid.
    it "reports a method_name assigned away" do
      complete!
      operation.method_name = nil

      expect(operation.problems.join).to include("method_name")
    end

    it "reports a blank method_name, which is not a method either" do
      complete!
      operation.method_name = "  "

      expect(operation.problems.join).to include("method_name")
    end

    it "reports every problem at once, not the first" do
      expect(operation.problems.size).to eq(3)
    end

    # §6.12 point 6, closing §17.1's M9a row. "Unsatisfiable" is only statically decidable for a
    # quorum whose eligibility is *closed*: it names its approvers and declares no permission rows,
    # so the count it names is a ceiling nobody can raise. Under all_quorums every quorum must be
    # met, so one such quorum makes the whole stage unreachable.
    describe "an unsatisfiable all_quorums stage" do
      let(:cfo) { Struct.new(:id, :name).new(1, "Cleo") }
      let(:counsel) { Struct.new(:id, :name).new(2, "Gene") }

      def workflow(satisfied_by:, threshold:, named:, permissions: nil)
        operation.version = "2026-09-13"
        operation.service = "Members::UpdateRoles"
        operation.workflow do |w|
          w.stage :approval, satisfied_by: satisfied_by do |q|
            q.quorum :named, eligible_actors: named, permissions: permissions, threshold: threshold
            q.quorum :other, permissions: %w(owner), threshold: 1
          end
        end
      end

      it "reports a quorum that names fewer approvers than its threshold" do
        workflow(satisfied_by: :all_quorums, threshold: 2, named: [cfo])

        expect(operation.problems.join).to include("quorum :named names 1 approver and needs 2")
      end

      it "says why it can never be satisfied, not merely that it is not" do
        workflow(satisfied_by: :all_quorums, threshold: 3, named: [cfo, counsel])

        expect(operation.problems.join).to include("declares no permissions")
      end

      it "accepts a quorum that names exactly its threshold" do
        workflow(satisfied_by: :all_quorums, threshold: 2, named: [cfo, counsel])

        expect(operation.problems).to be_empty
      end

      it "accepts a quorum that names more than its threshold" do
        workflow(satisfied_by: :all_quorums, threshold: 1, named: [cfo, counsel])

        expect(operation.problems).to be_empty
      end

      # Eligibility is open again the moment a permission row is there: a host can grant it to
      # anyone, so nothing about the declaration bounds the count (§5.3).
      it "accepts a quorum that also declares permissions, whatever it names" do
        workflow(satisfied_by: :all_quorums, threshold: 5, named: [cfo], permissions: %w(director))

        expect(operation.problems).to be_empty
      end

      # Under any_quorum the other quorums are alternative routes, so one unreachable rule does not
      # make the stage unreachable. §6.12 scopes the check to all_quorums for that reason.
      it "leaves an any_quorum stage alone, where another quorum can carry it" do
        workflow(satisfied_by: :any_quorum, threshold: 2, named: [cfo])

        expect(operation.problems).to be_empty
      end

      it "refuses it at declaration, where the mistake was made" do
        expect do
          ChangeRequests.operations.define("orders.pay") do |op|
            op.version = "2026-09-13"
            op.service = "Orders::Pay"
            op.workflow do |w|
              w.stage :approval, satisfied_by: :all_quorums do |q|
                q.quorum :named, eligible_actors: [cfo], threshold: 2
                q.quorum :other, permissions: %w(owner), threshold: 1
              end
            end
          end
        end.to raise_error(ChangeRequests::ConfigurationError, /names 1 approver and needs 2/)
      end
    end

    # Resolving the constant needs the host's classes loaded, so it runs at boot and nowhere else.
    it "says nothing about the target, which only verify! resolves" do
      complete!
      operation.service = "Members::NoSuchThing"

      expect(operation.problems).to be_empty
    end
  end

  def complete!
    operation.version = "2026-09-11"
    operation.service = "Members::UpdateRoles"
    operation.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
  end
end
