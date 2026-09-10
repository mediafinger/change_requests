# frozen_string_literal: true

require "rails_helper"

ProbeTable.create!(:immutable_probes)

class ImmutableProbe < ChangeRequests::Record
  self.table_name = "immutable_probes"

  include ChangeRequests::Concerns::Immutable
end

RSpec.describe ChangeRequests::Concerns::Immutable do
  subject(:probe) { ImmutableProbe.create!(label: "written once") }

  it "allows the row to be created" do
    expect(probe).to be_persisted
  end

  describe "updates" do
    it "are refused" do
      probe.label = "changed"

      expect { probe.save! }.to raise_error(ActiveRecord::ReadOnlyRecord, /append-only/)
    end

    it "are refused whichever attribute changed" do
      probe.payload = { "edited" => true }

      expect { probe.save! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "leave the row as it was" do
      probe.label = "changed"
      suppress(ActiveRecord::ReadOnlyRecord) { probe.save }

      expect(probe.reload.label).to eq("written once")
    end
  end

  # Blocking updates and leaving destroy open would be a lock on the front door only: an audit trail
  # a caller can delete a row from is not an audit trail (§5.5).
  describe "deletes" do
    it "are refused" do
      expect { probe.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord, /append-only/)
    end

    it "leave the row in place" do
      suppress(ActiveRecord::ReadOnlyRecord) { probe.destroy }

      expect(ImmutableProbe.exists?(probe.id)).to be(true)
    end
  end

  it "names the model in the message, so the failure says what refused" do
    probe.label = "changed"

    expect { probe.save! }.to raise_error(/ImmutableProbe rows/)
  end

  # `touch` and `update_columns` go straight to an UPDATE without running `before_update`. Documented
  # rather than defended, like the same hole in ReadonlyAttributes: neither is anybody's accident,
  # and a gem cannot lock a database it does not own.
  it "does not defend against touch, which bypasses callbacks on purpose" do
    expect { probe.touch }.not_to raise_error
  end

  # The one path that legitimately removes these rows is the request's own ON DELETE CASCADE, which
  # is between the database and itself and never passes through a callback.
  it "does not stand in the way of a database-level cascade" do
    expect { ImmutableProbe.connection.delete("DELETE FROM immutable_probes") }.not_to raise_error
  end
end
