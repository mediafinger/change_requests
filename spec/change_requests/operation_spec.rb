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

    it "is not idempotent unless the declaration says so (§8)" do
      expect(operation.idempotent).to be(false)
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

    it "reports every problem at once, not the first" do
      expect(operation.problems.size).to eq(3)
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
