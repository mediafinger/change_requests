# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Event do
  subject(:event) { change_request.events.create!(**attributes) }

  let(:change_request) { build_request }

  let(:attributes) do
    {
      actor_type: "User", actor_id: "1", actor_label: "Ada Lovelace",
      kind: "requested", operation_version: "2026-09-10", occurred_at: Time.current
    }
  end

  it "derives its table from the prefix" do
    expect(described_class.table_name).to eq("change_request_events")
  end

  describe "kind" do
    it "lists §5.5's sixteen" do
      expect(described_class::KINDS.size).to eq(16)
    end

    it "rejects one that is not listed" do
      expect(change_request.events.build(**attributes, kind: "shrugged")).not_to be_valid
    end

    it "requires one" do
      expect(change_request.events.build(**attributes, kind: nil)).not_to be_valid
    end

    it "answers a predicate" do
      expect(event).to be_requested
      expect(event).not_to be_executed
    end

    it "scopes by each" do
      event
      change_request.events.create!(**attributes, kind: "commented", body: "Waiting on legal")

      expect(described_class.commented.count).to eq(1)
    end

    # §19.16: a CHECK would make every later milestone's new kind a host migration.
    it "is enforced in Ruby, not by a database constraint" do
      row = change_request.events.build(**attributes, kind: "shrugged")

      expect { row.save!(validate: false) }.not_to raise_error
    end
  end

  describe "required columns" do
    %i(operation_version occurred_at actor_id actor_label).each do |attribute|
      it "requires #{attribute}" do
        expect(change_request.events.build(**attributes, attribute => nil)).not_to be_valid
      end
    end

    it "leaves body optional" do
      expect(event.body).to be_nil
    end

    it "defaults metadata to an empty object" do
      expect(event.metadata).to eq({})
    end

    it "stores metadata as jsonb, read back whole" do
      other = change_request.events.create!(**attributes, kind: "stage_satisfied",
                                                          metadata: { "stage" => "operational" })

      expect(other.reload.metadata).to eq("stage" => "operational")
    end
  end

  # §5.5: the version in force when *this* transition happened, which is not necessarily the one the
  # request was created under.
  it "carries its own operation_version, so the table exports alone" do
    change_request.update!(status: "approved")
    other = change_request.events.create!(**attributes, kind: "approved", operation_version: "2026-10-01")

    expect(other.operation_version).to eq("2026-10-01")
    expect(change_request.operation_version).to eq("2026-09-10")
  end

  describe "the actor triple" do
    it "accepts a registered class" do
      expect(change_request.events.build(**attributes, actor_type: "Manager")).to be_valid
    end

    it "rejects one that is not registered" do
      expect(change_request.events.build(**attributes, actor_type: "Robot")).not_to be_valid
    end

    describe "the System sentinel" do
      subject(:event) { change_request.events.create!(**attributes, **described_class::SYSTEM_ATTRIBUTES) }

      it "passes the allowlist without being registered" do
        expect(ChangeRequests.config.actor_types.keys).not_to include("System")
        expect(event).to be_persisted
      end

      it "is recognisable" do
        expect(event).to be_system_actor
      end

      it "is scopeable, which is how a report separates gem-originated rows" do
        event
        change_request.events.create!(**attributes, kind: "commented")

        expect(described_class.by_system.count).to eq(1)
      end

      # `*_id` is a string column shared with string-keyed host actors, and "0" is a value one of
      # those could legitimately hold.
      it "uses the word system as its id, not a numeric-looking one" do
        expect(ChangeRequests::SYSTEM_ACTOR[:id]).to eq("system")
      end
    end

    it "is never nil, so no presenter branches on it" do
      %i(actor_type actor_id actor_label).each do |column|
        expect(described_class.columns_hash[column.to_s].null).to be(false)
      end
    end
  end

  # Q5: an audit trail a caller can quietly update or delete a row from is not an audit trail.
  describe "immutability" do
    it "refuses an update" do
      event.body = "Rewritten"

      expect { event.save! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "refuses a destroy" do
      expect { event.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "leaves the row as written" do
      event.body = "Rewritten"
      suppress(ActiveRecord::ReadOnlyRecord) { event.save }

      expect(event.reload.body).to be_nil
    end

    # The only path that removes an event, and the gem never triggers it.
    it "goes when its request does, through the database cascade" do
      event
      change_request.destroy

      expect(described_class.where(id: event.id)).to be_empty
    end
  end

  describe "timestamps" do
    it "sets created_at" do
      expect(event.created_at).to be_present
    end

    # The column does not exist: a time that can never arrive is a promise the table does not keep.
    it "has no updated_at for Rails to maintain" do
      expect(described_class.column_names).not_to include("updated_at")
    end

    it "does not try to write one" do
      expect { change_request.events.create!(**attributes, kind: "commented") }.not_to raise_error
    end
  end

  describe "ordering" do
    it "reaches the request in the order things happened" do
      first = change_request.events.create!(**attributes, occurred_at: 2.hours.ago)
      second = change_request.events.create!(**attributes, kind: "approved", occurred_at: 1.hour.ago)

      expect(change_request.reload.events.to_a).to eq([first, second])
    end
  end

  # §5.5: "Every event is written through one path (emit in Commands::Base), so the column is
  # populated in a single place." A runtime spec could only prove it for the paths it exercises;
  # this proves it for the code, which is where a second write path would be introduced.
  describe "the single write path (§5.5)" do
    let(:writes) do
      /
        (?: \bChangeRequests::Event | \bEvent | \bevents )
        \s* (?: \.\s*(?:create|create!|new|build|insert|insert_all|upsert|upsert_all)\b | <<\s )
      /x
    end

    let(:emit) { File.expand_path("../../lib/change_requests/commands/base.rb", __dir__) }
    let(:domain_files) { Dir[File.expand_path("../../lib/**/*.rb", __dir__)] }

    it "scans the whole domain, so an empty result means something" do
      expect(domain_files.size).to be > 20
      expect(domain_files).to include(emit)
    end

    it "has teeth - the pattern matches the write it is guarding" do
      expect(File.read(emit)).to match(writes)
    end

    it "writes events nowhere but Commands::Base#emit" do
      offenders = (domain_files - [emit]).select { |path| File.read(path).match?(writes) }

      expect(offenders).to be_empty
    end
  end
end
