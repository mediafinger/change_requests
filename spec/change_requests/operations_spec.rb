# frozen_string_literal: true

RSpec.describe ChangeRequests::Operations do
  subject(:operations) { described_class.new }

  def define(key = "members.update_roles", **overrides)
    operations.define(key) do |op|
      op.version     = overrides.fetch(:version, "2026-09-11")
      op.service     = overrides.fetch(:service, "Members::UpdateRoles")
      op.method_name = overrides[:method_name] if overrides.key?(:method_name)
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
    end
  end

  describe "#define" do
    it "returns the declared operation" do
      expect(define).to be_a(ChangeRequests::Operation)
    end

    it "yields the operation so the declaration reads as a block (§6.4)" do
      yielded = nil

      operations.define("members.update_roles") do |op|
        op.version = "2026-09-11"
        op.service = "Members::UpdateRoles"
        op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
        yielded = op
      end

      expect(yielded).to be_a(ChangeRequests::Operation)
      expect(yielded.key).to eq("members.update_roles")
    end

    it "registers it under its key" do
      define "members.update_roles"

      expect(operations.keys).to eq(["members.update_roles"])
    end

    it "accepts a symbol key and stores a string, so lookup by either works" do
      define :"members.update_roles"

      expect(operations["members.update_roles"]).not_to be_nil
    end

    it "validates at declaration time, so a missing version fails on boot (§5.10)" do
      expect { operations.define("members.update_roles") { |op| op.service = "X" } }
        .to raise_error(ChangeRequests::ConfigurationError, /version/)
    end

    # M2-3: the completeness checks live on Operation#problems, which validate! reads, so an
    # operation that could never be requested cannot enter the registry either (§6.12 point 6).
    it "refuses a declaration with no workflow, which could never be approved" do
      expect { operations.define("members.update_roles") { |op| op.version = "1" } }
        .to raise_error(ChangeRequests::ConfigurationError, /no approvals/)
    end

    it "does not register an operation it refused" do
      expect { operations.define("members.update_roles") { |op| op.service = "X" } }
        .to raise_error(ChangeRequests::ConfigurationError)

      expect(operations.keys).to be_empty
    end

    it "refuses a declaration with no block, rather than raising LocalJumpError" do
      expect { operations.define("members.update_roles") }.to raise_error(ArgumentError, /block/)
    end

    # A reloading development boot re-runs the initializer; the last declaration is the live one.
    it "replaces an earlier declaration of the same key" do
      first  = define("members.update_roles", version: "1")
      second = define("members.update_roles", version: "2")

      expect(operations.keys).to eq(["members.update_roles"])
      expect(operations["members.update_roles"]).to equal(second)
      expect(operations["members.update_roles"]).not_to equal(first)
    end
  end

  describe "#[]" do
    it "finds a declared operation" do
      operation = define "members.update_roles"

      expect(operations["members.update_roles"]).to equal(operation)
    end

    it "looks up by symbol too" do
      operation = define "members.update_roles"

      expect(operations[:"members.update_roles"]).to equal(operation)
    end

    # Nil, not a raise: every guard asks this question, and §5.11 makes the answer a refusal the
    # guard words itself, not an exception from the registry.
    it "returns nil for an operation that is no longer declared (§5.11)" do
      expect(operations["members.update_roles"]).to be_nil
    end
  end

  describe "#keys" do
    it "lists the declared keys in declaration order" do
      define "b.second"
      define "a.first"

      expect(operations.keys).to eq(%w(b.second a.first))
    end
  end

  describe "#clear" do
    it "empties the registry" do
      define "members.update_roles"

      operations.clear

      expect(operations.keys).to be_empty
    end
  end

  describe "#dup" do
    # What spec/support/global_state.rb relies on to isolate examples from one another.
    it "copies the registry, so declaring on the copy leaves the original alone" do
      define "members.update_roles"

      copy = operations.dup
      copy.define("orders.refund") do |op|
        op.version = "1"
        op.service = "Orders::Refund"
        op.workflow { |w| w.stage :approval, permissions: %w(owner) }
      end
      copy.clear

      expect(operations.keys).to eq(["members.update_roles"])
    end
  end

  describe "ChangeRequests.operations" do
    it "is the memoised registry, so declarations accumulate across initializers" do
      expect(ChangeRequests.operations).to be_a(described_class)
      expect(ChangeRequests.operations).to equal(ChangeRequests.operations)
    end
  end
end
