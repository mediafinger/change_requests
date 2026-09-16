# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::ActorRef do
  subject(:ref) { described_class.new(type: "Admin", id: admin.id.to_s, label: "Ada (admin)") }

  let(:admin) { Admin.create!(name: "Ada") }

  def gone
    described_class.new(type: "Admin", id: "999999999", label: "Ada (admin)")
  end

  describe "the stored triple" do
    it "answers type and id with no query at all" do
      ref
      expect(ref.type).to eq("Admin")
      expect(ref.id).to eq(admin.id.to_s)

      expect { ref.type && ref.id && ref.snapshot }.to issue_no_queries
    end

    it "keeps the id as a string, exactly as stored (§5.7)" do
      expect(described_class.new(type: "Admin", id: 42).id).to eq("42")
    end

    it "keeps the snapshot as it was recorded" do
      expect(ref.snapshot).to eq("Ada (admin)")
    end

    it "carries the identity when the reference snapshots one (§9.4)" do
      expect(described_class.new(type: "Admin", id: "1", identity: "person-7").identity)
        .to eq("person-7")
    end
  end

  describe "#to_h" do
    it "is the triple the reader returned before this class existed" do
      expect(ref.to_h).to eq(type: "Admin", id: admin.id.to_s, label: "Ada (admin)")
    end

    it "omits a column the reference does not carry" do
      expect(described_class.new(type: "Admin", id: "1").to_h).to eq(type: "Admin", id: "1")
    end

    it "includes identity when the reference carries one" do
      expect(described_class.new(type: "Admin", id: "1", label: "Ada", identity: "p7").to_h)
        .to eq(type: "Admin", id: "1", label: "Ada", identity: "p7")
    end

    # It is the row, and reading a row should not query. `#label` is the resolved view.
    it "reports the snapshot rather than resolving, so it stays free" do
      ref
      admin.update!(name: "Renamed")

      expect { expect(ref.to_h[:label]).to eq("Ada (admin)") }.to issue_no_queries
    end
  end

  describe "#record" do
    it "resolves the host record" do
      expect(ref.record).to eq(admin)
    end

    it "memoises, so a page asking twice queries once" do
      ref # built before measuring, or the Admin's INSERT lands inside the count

      expect { ref.record }.to issue_queries(1)
      expect { ref.record }.to issue_no_queries
    end

    # Without the sentinel, a deleted actor is re-queried on every call.
    it "memoises a miss too" do
      missing = gone
      missing.record

      expect { missing.record }.to issue_no_queries
    end

    it "is nil once the record is gone" do
      expect(gone.record).to be_nil
    end
  end

  # §11: deleted actors degrade, never raise. A page rendering a five-year-old request must not
  # blow up because someone deleted a model.
  describe "degrading rather than raising" do
    it "resolves nothing for an unregistered actor type" do
      expect(described_class.new(type: "Ghost", id: "1", label: "Ghost").record).to be_nil
    end

    it "resolves nothing for a registered type whose class no longer exists" do
      ChangeRequests.config.actor_type("Vanished") { |t| t.label = ->(record) { record.name } }

      expect(described_class.new(type: "Vanished", id: "1", label: "Old").record).to be_nil
    end

    # M4-2 removes the need for this by casting per key_type before the finder sees the id.
    it "resolves nothing for an id that cannot be cast to the column's type" do
      expect(described_class.new(type: "Admin", id: "not-a-number", label: "Ada").record).to be_nil
    end

    it "keeps the label and the triple whatever happened to the record" do
      expect(gone).to have_attributes(label: "Ada (admin)", type: "Admin")
    end
  end

  describe "#resolved? and #deleted?" do
    it "is resolved while the record is there" do
      expect(ref).to be_resolved
      expect(ref).not_to be_deleted
    end

    it "is deleted once it is not" do
      expect(gone).to be_deleted
      expect(gone).not_to be_resolved
    end
  end

  # §19.5, and the first thing ever to read config.actor_label_strategy.
  describe "#label and config.actor_label_strategy" do
    it "prefers the live label under :live, which is the default" do
      expect(ChangeRequests.config.actor_label_strategy).to eq(:live)

      admin.update!(name: "Renamed")

      expect(ref.label).to eq("Renamed (admin)")
    end

    it "falls back to the snapshot under :live when the record is gone" do
      expect(gone.label).to eq("Ada (admin)")
    end

    it "falls back to the snapshot when the live label comes back blank" do
      ChangeRequests.config.actor_types["Admin"].label = ->(_admin) { "" }

      expect(ref.label).to eq("Ada (admin)")
    end

    it "returns the snapshot under :snapshot" do
      ChangeRequests.config.actor_label_strategy = :snapshot
      admin.update!(name: "Renamed")

      expect(ref.label).to eq("Ada (admin)")
    end

    # The only way to render a page with no query against the host's tables (§11).
    it "never resolves under :snapshot, asserted by counting rather than by trusting the branch" do
      ref
      ChangeRequests.config.actor_label_strategy = :snapshot

      expect { ref.label }.to issue_no_queries
    end
  end

  describe "#path" do
    before do
      ChangeRequests.config.actor_types["Admin"].path = ->(admin, routes) { routes.admin_path(admin) }
    end

    let(:routes) { double(admin_path: "/admins/1") }

    it "asks the registered lambda" do
      expect(ref.path(routes)).to eq("/admins/1")
    end

    # A job and an API controller both have none, and neither is an error (§11).
    it "is nil with no routes object" do
      expect(ref.path(nil)).to be_nil
    end

    it "is nil once the record is gone, so a view renders no link" do
      expect(gone.path(routes)).to be_nil
    end

    it "is nil when the type declares no path" do
      ChangeRequests.config.actor_types["Admin"].path = nil

      expect(ref.path(routes)).to be_nil
    end
  end

  # §19.15: the sentinel is an ActorRef like any other, so a timeline never branches on it.
  # §11's fast path: `RequestPresenter.new(resolve_actors: false)` renders from the row alone.
  describe "#without_resolution" do
    subject(:unresolving) { ref.without_resolution }

    before { ref }

    it "answers from the row with no query, even under :live labels" do
      ChangeRequests.config.actor_label_strategy = :live
      admin.update!(name: "Renamed")

      expect { expect(unresolving.label).to eq("Ada (admin)") }.to issue_no_queries
    end

    it "has no record and no path" do
      expect { expect([unresolving.record, unresolving.path(Object.new)]).to eq([nil, nil]) }.to issue_no_queries
    end

    # Nobody looked, so nobody knows. "(deleted)" would be a false claim about the host's data.
    it "is neither resolved nor deleted" do
      expect([unresolving.resolved?, unresolving.deleted?]).to eq([false, false])
    end

    it "is not deleted even when the record is gone" do
      expect(gone.without_resolution).not_to be_deleted
    end

    it "is not resolving, where the original is" do
      expect([ref.resolving?, unresolving.resolving?]).to eq([true, false])
    end

    it "equals the ref it was copied from, since equality is the stored triple" do
      expect(unresolving).to eq(ref)
    end

    it "keeps identity" do
      original = described_class.new(type: "Admin", id: "1", label: "Ada", identity: "p7")

      expect(original.without_resolution.to_h).to eq(original.to_h)
    end

    it "leaves the original free to resolve" do
      unresolving

      expect(ref.record).to eq(admin)
    end
  end

  describe "the System sentinel" do
    subject(:system) { described_class.new(**ChangeRequests::SYSTEM_ACTOR) }

    it "reads as an ordinary ref" do
      expect(system).to have_attributes(type: "System", id: "system", label: "System")
    end

    it "resolves to nothing, System being nobody's class" do
      expect(system.record).to be_nil
      expect(system).to be_deleted
    end

    it "round-trips the constant" do
      expect(system.to_h).to eq(ChangeRequests::SYSTEM_ACTOR)
    end
  end

  describe "equality" do
    it "compares by the stored triple, so two reads of one row are equal" do
      expect(ref).to eq(described_class.new(type: "Admin", id: admin.id.to_s, label: "Ada (admin)"))
    end

    it "distinguishes two actors of the same class" do
      expect(ref).not_to eq(described_class.new(type: "Admin", id: "2", label: "Ada (admin)"))
    end

    it "is not equal to the bare hash, which is what to_h is for" do
      expect(ref).not_to eq(ref.to_h)
    end

    it "hashes by the triple, so refs deduplicate in a Set" do
      expect([ref, described_class.new(**ref.to_h)].uniq.size).to eq(1)
    end
  end
end
