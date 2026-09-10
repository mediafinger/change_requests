# frozen_string_literal: true

require "rails_helper"

ProbeTable.create!(:terminal_probes)

class TerminalProbe < ChangeRequests::Record
  self.table_name = "terminal_probes"

  include ChangeRequests::Concerns::TerminalStateGuard

  terminal_states :successful, :rejected, :canceled, :expired
end

RSpec.describe ChangeRequests::Concerns::TerminalStateGuard do
  subject(:probe) { TerminalProbe.create!(status: "pending") }

  it "records which states are final" do
    expect(TerminalProbe.terminal_state_values).to eq(%w(successful rejected canceled expired))
  end

  describe "#final?" do
    it "is false while the request is still moving" do
      expect(probe).not_to be_final
    end

    it "is true once it has stopped" do
      expect(TerminalProbe.new(status: "canceled")).to be_final
    end
  end

  describe "while not yet final" do
    it "allows an ordinary update" do
      probe.update!(label: "still going")

      expect(probe.reload.label).to eq("still going")
    end

    # The check reads `status_was`, the value the row had *before* this save - so arriving at a
    # final state is allowed, and leaving one is not (§5.8).
    it "allows the transition into a final state" do
      probe.update!(status: "canceled")

      expect(probe.reload.status).to eq("canceled")
    end
  end

  describe "once final" do
    subject(:probe) { TerminalProbe.create!(status: "successful") }

    it "refuses a status change" do
      probe.status = "pending"

      expect { probe.save! }.to raise_error(ChangeRequests::AlreadyFinalized)
    end

    it "refuses any other change too, not merely a status one" do
      probe.label = "after the fact"

      expect { probe.save! }.to raise_error(ChangeRequests::AlreadyFinalized)
    end

    it "carries the row it refused, so a rescuer knows which" do
      probe.label = "after the fact"

      expect { probe.save! }.to raise_error(ChangeRequests::AlreadyFinalized) { |error|
        expect(error.request).to eq(probe)
      }
    end

    it "carries a machine-readable reason" do
      probe.label = "after the fact"

      expect { probe.save! }.to raise_error(ChangeRequests::AlreadyFinalized) { |error|
        expect(error.reason).to eq(:already_finalized)
      }
    end

    it "leaves the row as it was" do
      probe.status = "pending"
      suppress(ChangeRequests::AlreadyFinalized) { probe.save }

      expect(probe.reload.status).to eq("successful")
    end
  end

  # §5.8: terminal-state protection applies to the request row's own lifecycle, not to appending to
  # the audit trail. Events and attempts are separate rows, and commenting on a finished request is
  # the point of having a trail at all (§5.5).
  it "says nothing about other tables, which is how a finished request still accepts comments" do
    TerminalProbe.create!(status: "successful")

    expect { TerminalProbe.create!(status: "pending") }.not_to raise_error
  end
end
