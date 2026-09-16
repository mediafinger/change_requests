# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::ActorResolver do
  def ref(type, id, label = "Snapshot")
    ChangeRequests::ActorRef.new(type: type, id: id.to_s, label: label)
  end

  let(:admin) { Admin.create!(name: "Ada") }
  let(:user) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:manager) { Manager.create!(id: "mgr-1", name: "Olive") }

  describe "one query per actor type" do
    # §11's promise, and the reason CollectionPresenter owns eager loading: three actor classes on
    # a page of twenty-five requests cost three queries, not seventy-five.
    it "resolves a page of twenty-five across three classes in three queries" do
      admins = Array.new(9) { |i| Admin.create!(name: "Admin #{i}") }
      users = Array.new(8) { |i| User.create!(name: "User #{i}", email: "u#{i}@example.com") }
      managers = Array.new(8) { |i| Manager.create!(id: "mgr-#{i}", name: "Manager #{i}") }

      refs = admins.map { |a| ref("Admin", a.id) } +
             users.map { |u| ref("User", u.id) } +
             managers.map { |m| ref("Manager", m.id) }

      expect(refs.size).to eq(25)
      expect { described_class.call(refs) }.to issue_queries(3)
      expect(refs).to all(be_resolved)
    end

    it "asks once per type however many refs share it" do
      others = Array.new(5) { |i| Admin.create!(name: "Other #{i}") }
      refs = others.map { |a| ref("Admin", a.id) }

      expect { described_class.call(refs) }.to issue_queries(1)
    end

    # The whole point of filling the memo: nothing resolves itself afterwards.
    it "leaves the refs answered, so asking for a record costs nothing" do
      refs = [ref("Admin", admin.id)]
      described_class.call(refs)

      expect { expect(refs.first.record).to eq(admin) }.to issue_no_queries
    end

    it "skips a ref built not to resolve" do
      unresolving = ref("Admin", admin.id).without_resolution

      expect { described_class.call([unresolving]) }.to issue_no_queries
      expect(unresolving).not_to be_deleted
    end

    it "skips refs a caller already resolved rather than querying again" do
      resolved = ref("Admin", admin.id)
      resolved.record

      expect { described_class.call([resolved]) }.to issue_no_queries
    end

    it "issues nothing at all for an empty collection" do
      expect { described_class.call([]) }.to issue_no_queries
    end
  end

  describe "what it hands back" do
    it "gives each ref its own record" do
      refs = [ref("Admin", admin.id), ref("User", user.id), ref("Manager", manager.id)]

      described_class.call(refs)

      expect(refs.map(&:record)).to eq([admin, user, manager])
    end

    # Missing ids are absent from the finder's result, never nil placeholders and never an
    # exception - the ref simply reports itself deleted (§11).
    it "marks a ref whose record is gone as deleted, and resolves the rest" do
      present = ref("Admin", admin.id)
      missing = ref("Admin", 999_999_999)

      described_class.call([present, missing])

      expect(present).to be_resolved
      expect(missing).to be_deleted
      expect(missing.label).to eq("Snapshot")
    end

    it "returns the refs it was given" do
      refs = [ref("Admin", admin.id)]

      expect(described_class.call(refs)).to eq(refs)
    end

    it "ignores nils in the collection, which is every optional executer on a page" do
      present = ref("Admin", admin.id)

      expect { described_class.call([nil, present, nil]) }.to issue_queries(1)
      expect(present).to be_resolved
    end
  end

  describe "an actor class the application no longer has" do
    it "does not prevent the page from resolving the others" do
      ChangeRequests.config.actor_type("Vanished") { |t| t.label = ->(record) { record.name } }
      gone = ref("Vanished", "1")
      present = ref("Admin", admin.id)

      described_class.call([gone, present])

      expect(gone).to be_deleted
      expect(present).to be_resolved
    end

    it "resolves nothing for a type nobody registered, without querying for it" do
      stranger = ref("Ghost", "1")

      expect { described_class.call([stranger]) }.to issue_no_queries
      expect(stranger).to be_deleted
    end
  end

  # Q2: key_type governs the cast, and anything that will not cast is dropped before the finder
  # ever sees it. A host's finder should not have to defend against a malformed id.
  describe "casting ids per key_type" do
    def recording_finder(type)
      seen = []
      ChangeRequests.config.actor_types[type].finder = lambda do |ids|
        seen << ids

        type.constantize.where(id: ids)
      end

      seen
    end

    it "parses an integer key and drops what will not parse" do
      seen = recording_finder("Admin")

      described_class.call([ref("Admin", admin.id), ref("Admin", "not-a-number")])

      expect(seen).to eq([[admin.id]])
    end

    it "keeps a uuid key that matches the format and drops one that does not" do
      seen = recording_finder("User")

      described_class.call([ref("User", user.id), ref("User", "42")])

      expect(seen).to eq([[user.id]])
    end

    it "passes a string key through verbatim, which is the escape hatch for any other key shape" do
      seen = recording_finder("Manager")

      described_class.call([ref("Manager", "mgr-1"), ref("Manager", "anything-at-all")])

      expect(seen).to eq([%w(mgr-1 anything-at-all)])
    end

    it "does not call the finder at all when every id is dropped" do
      seen = recording_finder("Admin")

      expect { described_class.call([ref("Admin", "nope")]) }.to issue_no_queries
      expect(seen).to be_empty
    end

    it "deduplicates, so two refs to one actor are asked for once" do
      seen = recording_finder("Admin")

      described_class.call([ref("Admin", admin.id), ref("Admin", admin.id)])

      expect(seen).to eq([[admin.id]])
    end
  end

  describe "a host's own finder" do
    it "is called exactly once per type, with every id of that type" do
      other = Admin.create!(name: "Ben")
      calls = []
      ChangeRequests.config.actor_types["Admin"].finder = lambda do |ids|
        calls << ids

        Admin.where(id: ids)
      end

      described_class.call([ref("Admin", admin.id), ref("Admin", other.id)])

      expect(calls.size).to eq(1)
      expect(calls.sole).to contain_exactly(admin.id, other.id)
    end

    it "can narrow what resolves, which is how a soft delete is honoured" do
      ChangeRequests.config.actor_types["Admin"].finder = ->(_ids) { Admin.none }
      hidden = ref("Admin", admin.id)

      described_class.call([hidden])

      expect(hidden).to be_deleted
      expect(hidden.label).to eq("Snapshot")
    end

    it "falls back to the derived default when the type declares none" do
      expect(ChangeRequests.config.actor_types["Admin"].finder.call([admin.id])).to eq([admin])
    end
  end

  describe "tenants" do
    it "resolves them too, a tenant reference being an ActorRef like any other" do
      organization = Organization.create!(name: "Acme")
      tenant = ref("Organization", organization.id)

      described_class.call([tenant])

      expect(tenant.record).to eq(organization)
    end
  end
end
