# frozen_string_literal: true

RSpec.describe ChangeRequests::Configuration do
  subject(:config) { described_class.new }

  def register_valid_actor_type(config)
    config.actor_type "User" do |type|
      type.label       = ->(user) { user.name }
      type.permissions = ->(user) { user.roles }
    end
  end

  describe "defaults" do
    it "starts with no actor and no tenant types registered" do
      expect(config.actor_types).to be_empty
      expect(config.tenant_types).to be_empty
    end

    it "prefers live labels, falling back to the snapshot (§19.5)" do
      expect(config.actor_label_strategy).to eq(:live)
    end

    it "matches any listed permission unless a quorum says otherwise (§5.3)" do
      expect(config.default_permission_match).to eq(:any)
    end

    it "carries no cross-class identity until a host supplies one (§9.4)" do
      expect(config.actor_identity).to be_nil
    end

    it "authorizes through the permission rows by default (§9.2)" do
      expect(config.authorization).to be_a(ChangeRequests::Authorization::Permissions)
    end

    it "separates duties: the requester may not execute, an approver may" do
      expect(config.requester_may_execute).to be(false)
      expect(config.approver_may_execute).to be(true)
    end

    it "keeps the break-glass override off until a host asks for it (§8.1)" do
      expect(config.requester_may_override).to be(false)
    end

    it "stops the request on a rejection, attempts once, and never expires" do
      expect(config.only_record_rejections).to be(false)
      expect(config.default_max_attempts).to eq(1)
      expect(config.default_expires_in).to be_nil
    end
  end

  describe "#actor_type" do
    it "registers a class under its full constant name" do
      config.actor_type("Accounts::Admin") { |type| type.label = ->(a) { a.name } }

      expect(config.actor_types.keys).to eq(["Accounts::Admin"])
    end

    it "yields the registration so it can be configured" do
      config.actor_type "User" do |type|
        type.key_type    = :uuid
        type.label       = ->(user) { user.email }
        type.permissions = ->(user) { user.roles }
        type.may_request = false
      end

      type = config.actor_types.fetch("User")

      expect(type.key_type).to eq(:uuid)
      expect(type.may_request).to be(false)
    end

    it "defaults to a class that may request, approve and execute" do
      type = config.actor_type("User")

      expect([type.may_request, type.may_approve, type.may_execute]).to all(be(true))
    end

    # Declarations may be split across several initializers, so a second call has to reopen the
    # registration rather than replace it.
    it "merges a re-registration instead of replacing it" do
      config.actor_type("User") { |type| type.label = ->(user) { user.name } }
      config.actor_type("User") { |type| type.key_type = :uuid }

      type = config.actor_types.fetch("User")

      expect(config.actor_types.size).to eq(1)
      expect(type.key_type).to eq(:uuid)
      expect(type.label).not_to be_nil
    end

    it "returns the same registration object on every call" do
      expect(config.actor_type("User")).to equal(config.actor_type("User"))
    end
  end

  describe "#tenant_type" do
    it "registers tenants through the same singular form as actors (§10)" do
      config.tenant_type("Organization") { |type| type.label = ->(org) { org.name } }

      expect(config.tenant_types.keys).to eq(["Organization"])
    end
  end

  describe "#requester_may_override" do
    it "can be turned on by a host that means it (§8.1)" do
      config.requester_may_override = true

      expect(config.requester_may_override).to be(true)
    end
  end

  describe "#validate!" do
    it "passes on a sound configuration" do
      register_valid_actor_type(config)

      expect(config.validate!).to be(true)
    end

    it "names the problem when no actor type is registered" do
      expect { config.validate! }
        .to raise_error(ChangeRequests::ConfigurationError, /No actor types are registered/)
    end

    it "tells the host how to register one" do
      expect { config.validate! }.to raise_error(/config\.actor_type "User"/)
    end

    it "rejects an unknown key type, listing the ones that exist" do
      config.actor_type("User") { |type| type.key_type = :guid; type.label = ->(u) { u.name } }
      config.actor_type("User") { |type| type.may_approve = false }

      expect { config.validate! }
        .to raise_error(/ActorType "User" has key_type :guid.+:uuid, :integer, :string/m)
    end

    it "rejects an actor type without a label, since labels are snapshotted" do
      config.actor_type("User") { |type| type.may_approve = false }

      expect { config.validate! }.to raise_error(/ActorType "User" needs a label/)
    end

    it "rejects an approving actor type without a permission set" do
      config.actor_type("User") { |type| type.label = ->(user) { user.name } }

      expect { config.validate! }.to raise_error(/may approve but has no permissions/)
    end

    it "accepts a non-approving actor type without a permission set" do
      config.actor_type "User" do |type|
        type.label       = ->(user) { user.name }
        type.may_approve = false
      end

      expect(config.validate!).to be(true)
    end

    it "validates tenant registrations too" do
      register_valid_actor_type(config)
      config.tenant_type("Organization")

      expect { config.validate! }.to raise_error(/TenantType "Organization" needs a label/)
    end

    it "rejects an unknown label strategy" do
      register_valid_actor_type(config)
      config.actor_label_strategy = :fresh

      expect { config.validate! }
        .to raise_error(/actor_label_strategy is :fresh.+:live or :snapshot/m)
    end

    it "rejects an unknown default permission match" do
      register_valid_actor_type(config)
      config.default_permission_match = :some

      expect { config.validate! }.to raise_error(/default_permission_match is :some/)
    end

    it "rejects an actor_identity that cannot be called" do
      register_valid_actor_type(config)
      config.actor_identity = :person_id

      expect { config.validate! }.to raise_error(/actor_identity is :person_id/)
    end

    it "accepts a nil actor_identity, which is the default" do
      register_valid_actor_type(config)
      config.actor_identity = nil

      expect(config.validate!).to be(true)
    end

    it "rejects a max attempts below one" do
      register_valid_actor_type(config)
      config.default_max_attempts = 0

      expect { config.validate! }.to raise_error(/default_max_attempts is 0/)
    end

    # One boot should fix one round of mistakes, not one mistake per boot.
    it "reports every problem at once" do
      config.actor_label_strategy      = :fresh
      config.default_permission_match  = :some

      expect { config.validate! }.to raise_error(ChangeRequests::ConfigurationError) { |error|
        expect(error.message.lines.grep(/^- /).size).to eq(3)
      }
    end
  end

  # What spec/support/global_state.rb relies on to give every example its own configuration.
  describe "#dup" do
    before { register_valid_actor_type(config) }

    it "copies the settings" do
      copy = config.dup
      copy.default_permission_match = :all

      expect(config.default_permission_match).to eq(:any)
    end

    it "copies the registries, so registering on the copy leaves the original alone" do
      copy = config.dup
      copy.actor_type("Admin") { |type| type.label = ->(admin) { admin.name } }
      copy.tenant_type("Organization") { |type| type.label = ->(org) { org.name } }

      expect(config.actor_types.keys).to eq(["User"])
      expect(config.tenant_types).to be_empty
    end

    # `actor_type` reopens an existing registration rather than replacing it, so copying the hash
    # is not enough - the registered objects have to be copied too.
    it "copies the registered types, so reopening one on the copy leaves the original alone" do
      copy = config.dup
      copy.actor_type("User") do |type|
        type.key_type    = :uuid
        type.may_approve = false
      end

      expect(config.actor_types.fetch("User").key_type).to eq(:integer)
      expect(config.actor_types.fetch("User").may_approve).to be(true)
    end

    it "copies the authorization strategy" do
      copy = config.dup

      expect(copy.authorization).to be_a(ChangeRequests::Authorization::Permissions)
      expect(copy.authorization).not_to equal(config.authorization)
    end
  end

  # §8, §10. Three keys M3b-1 added; §10 listed them long before the class had any of them.
  describe "execution mode (§8)" do
    it "runs inline unless the host says otherwise" do
      expect(config.execution_mode).to eq(:inline)
    end

    it "names the gem's own job class by default, as a string" do
      expect(config.job_class).to eq("ChangeRequests::Execution::Job")
      expect(config.job_queue).to eq(:default)
    end

    it "refuses an unknown mode" do
      config.execution_mode = :whenever

      expect(config.problems.join).to match(/execution_mode.*:inline or :background/)
    end

    # Deliberately not checked for resolvability: a headless process may have :background
    # configured and no ActiveJob, and refusing that would fail a boot that works (§8).
    it "accepts :background, which a process without ActiveJob may still configure" do
      config.execution_mode = :background

      expect(config.problems.grep(/execution_mode|job_/)).to be_empty
    end

    it "refuses a job_class that is not a name" do
      config.job_class = nil

      expect(config.problems.join).to include("job_class")
    end

    it "refuses an empty queue" do
      config.job_queue = "  "

      expect(config.problems.join).to include("job_queue")
    end
  end
end
