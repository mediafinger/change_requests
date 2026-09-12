# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dummy::Application" do
  it "boots" do
    expect(Rails.application).to be_a(Dummy::Application)
  end

  it "runs in the test environment" do
    expect(Rails.env).to eq("test")
  end

  # If `config.after_initialize` had raised, the app would not have booted at all - so reaching this
  # example is already most of the proof. Asserting it directly says which wiring is being trusted.
  it "passed the engine's boot-time configuration check (§10)" do
    expect(ChangeRequests.config.validate!).to be(true)
  end

  it "keeps the table name prefix through a full Rails boot" do
    expect(ChangeRequests.table_name_prefix).to eq("change_request_")
  end

  describe "the registered actor types" do
    it "registers four, because one tidy User class would hide the problem the schema solves" do
      expect(ChangeRequests.config.actor_types.keys)
        .to contain_exactly("User", "Admin", "Manager", "Director")
    end

    # Four classes, three key types: Director exists to be gated on by §6.9's `actor_type:` shapes,
    # and shares Admin's key so it adds a class the gem has never heard of and nothing else.
    it "spans three key types across them, which is what the schema exists to prove" do
      expect(ChangeRequests.config.actor_types.values.map(&:key_type).uniq)
        .to contain_exactly(:uuid, :integer, :string)
    end

    it "registers a tenant type" do
      expect(ChangeRequests.config.tenant_types.keys).to eq(["Organization"])
    end

    it "declares each actor's key type, which is how the resolver casts an id back (§5.7)" do
      key_types = ChangeRequests.config.actor_types.transform_values(&:key_type)

      expect(key_types)
        .to eq("User" => :uuid, "Admin" => :integer, "Manager" => :string, "Director" => :integer)
    end

    it "labels each class differently, so a snapshot cannot be mistaken for a lookup" do
      admin = Admin.create!(name: "Ada")

      label = ChangeRequests.config.actor_types.fetch("Admin").label

      expect(label.call(admin)).to eq("Ada (admin)")
    end
  end

  # §15.1: three primary key types in one application is the configuration the schema exists to
  # support. §5.7 consequence 1 - `*_id` is a string column - is only testable against it.
  describe "the host tables" do
    it "gives User a uuid primary key" do
      expect(User.columns_hash["id"].sql_type).to eq("uuid")
    end

    it "gives Admin a bigint primary key" do
      expect(Admin.columns_hash["id"].sql_type).to eq("bigint")
    end

    it "gives Manager a string primary key" do
      expect(Manager.columns_hash["id"].sql_type).to eq("character varying")
    end

    it "gives Organization a uuid primary key" do
      expect(Organization.columns_hash["id"].sql_type).to eq("uuid")
    end
  end

  describe "actors of every key type" do
    it "round-trip through one string column, which is what §5.7 is for" do
      user    = User.create!(name: "Ada", email: "ada@example.com", roles: %w(owner))
      admin   = Admin.create!(name: "Grace", roles: %w(reviewer))
      manager = Manager.create!(id: "mgr-1", name: "Alan", roles: %w(manager))

      ids = [user, admin, manager].map { |actor| actor.id.to_s }

      expect(ids).to all(be_a(String))
      expect(ids.last).to eq("mgr-1")
      expect(ids.first).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(ids[1]).to match(/\A\d+\z/)
    end

    it "are rolled back between examples, so one spec cannot see another's actors" do
      expect(Admin.count).to eq(0)
    end
  end
end
