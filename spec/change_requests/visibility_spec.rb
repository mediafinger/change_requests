# frozen_string_literal: true

require "rails_helper"

# §9.3: which requests can this actor see. Three settings and one scope, asserted together because
# the interesting behaviour is how they compose - and because `visible_to` and `undeclared` must
# never both contain a row.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "visibility (§9.3, §5.11)" do
  let(:acme) { Organization.create!(name: "Acme") }
  let(:other) { Organization.create!(name: "Other") }
  let(:alice) { User.create!(name: "Alice", email: "alice@example.com") }

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-16"
      op.service = "Members::UpdateRoles"
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
    end
  end

  def create(tenant: nil)
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                          requester: alice, tenant: tenant)
  end

  describe "the default visible_scope" do
    # A host that registers a tenant_type only to *record* the tenant - passing `tenant:` and never
    # wanting visibility narrowed - gets the identity scope. `tenant_for` is what asks for scoping.
    it "is the identity scope when the gem cannot work out an actor's tenant" do
      request = create(tenant: acme)

      expect(ChangeRequests.config.tenant_for).to be_nil
      expect(ChangeRequests::Request.visible_to(alice)).to include(request)
    end

    context "with config.tenant_for set" do
      before { ChangeRequests.config.tenant_for = ->(_actor) { acme } }

      it "narrows to the actor's own tenant" do
        mine = create(tenant: acme)
        theirs = create(tenant: other)

        expect(ChangeRequests::Request.visible_to(alice)).to eq([mine])
        expect(ChangeRequests::Request.visible_to(alice)).not_to include(theirs)
      end

      # Created before tenant_for was set, which is the only way to get one once it is: after
      # that, a request without an explicit tenant is stamped with the actor's.
      it "hides a request with no tenant at all, which belongs to nobody's tenant" do
        ChangeRequests.config.tenant_for = nil
        untenanted = create
        ChangeRequests.config.tenant_for = ->(_actor) { acme }

        expect(untenanted.tenant).to be_nil
        expect(ChangeRequests::Request.visible_to(alice)).not_to include(untenanted)
      end

      it "shows an actor with no tenant nothing, rather than everything" do
        create(tenant: acme)
        ChangeRequests.config.tenant_for = ->(_actor) {}

        expect(ChangeRequests::Request.visible_to(alice)).to be_empty
      end
    end
  end

  describe "a host's own visible_scope" do
    it "replaces the default entirely" do
      mine = create(tenant: acme)
      create(tenant: other)
      ChangeRequests.config.visible_scope = lambda { |scope, _actor|
        scope.where(tenant_id: acme.id.to_s)
      }

      expect(ChangeRequests::Request.visible_to(alice)).to eq([mine])
    end

    it "receives the scope and the actor" do
      create(tenant: acme)
      seen = []
      ChangeRequests.config.visible_scope = lambda { |scope, actor|
        seen << [scope.model, actor]

        scope
      }

      ChangeRequests::Request.visible_to(alice).to_a

      expect(seen).to eq([[ChangeRequests::Request, alice]])
    end

    it "still cannot see past the undeclared exclusion, which runs first" do
      create(tenant: acme)
      ChangeRequests.config.visible_scope = ->(scope, _actor) { scope }
      ChangeRequests.operations.clear

      expect(ChangeRequests::Request.visible_to(alice)).to be_empty
    end
  end

  # §5.11: a stranded request leaves inboxes and badges immediately, before any cleanup runs.
  describe "requests whose operation is no longer declared" do
    it "are invisible to everyone" do
      request = create

      expect(ChangeRequests::Request.visible_to(alice)).to include(request)

      ChangeRequests.operations.clear

      expect(ChangeRequests::Request.visible_to(alice)).to be_empty
    end

    it "are invisible whatever their status" do
      request = create
      request.update!(status: "successful")
      ChangeRequests.operations.clear

      expect(ChangeRequests::Request.visible_to(alice)).to be_empty
    end

    it "become visible again the moment the declaration comes back" do
      request = create
      ChangeRequests.operations.clear

      expect(ChangeRequests::Request.visible_to(alice)).to be_empty

      ChangeRequests.operations.define("members.update_roles") do |op|
        op.version = "2026-09-16"
        op.service = "Members::UpdateRoles"
        op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
      end

      expect(ChangeRequests::Request.visible_to(alice)).to include(request)
    end
  end

  # The pair that must not disagree. `undeclared` sweeps what `visible_to` hides, so a row in both
  # would be cancelled by a rake task while still showing in somebody's inbox.
  describe "visible_to against undeclared" do
    it "never both contain a row, with a declared registry" do
      create
      create(tenant: acme)

      overlap = ChangeRequests::Request.visible_to(alice) & ChangeRequests::Request.undeclared

      expect(ChangeRequests::Request.visible_to(alice)).not_to be_empty
      expect(overlap).to be_empty
    end

    # The case that would break a pair written twice: `IN ()` and `NOT IN ()` have to be each
    # other's complement, and Rails renders them as 1=0 and 1=1.
    it "never both contain a row, with nothing declared at all" do
      create
      create(tenant: acme)
      ChangeRequests.operations.clear

      expect(ChangeRequests::Request.visible_to(alice)).to be_empty
      expect(ChangeRequests::Request.undeclared.count).to eq(2)
    end

    it "partitions the open requests between them" do
      create
      stranded = create
      ChangeRequests.operations.clear

      expect(ChangeRequests::Request.undeclared).to include(stranded)
      expect(ChangeRequests::Request.visible_to(alice)).not_to include(stranded)
    end
  end

  describe "config.tenant_for and Commands::Create" do
    before { ChangeRequests.config.tenant_for = ->(_actor) { acme } }

    it "stamps the tenant a caller did not pass" do
      expect(create.tenant.to_h)
        .to eq(type: "Organization", id: acme.id.to_s, label: "Acme")
    end

    it "leaves an explicit tenant alone, which always wins" do
      expect(create(tenant: other).tenant.to_h)
        .to eq(type: "Organization", id: other.id.to_s, label: "Other")
    end

    it "stamps nothing when it returns nil for this actor" do
      ChangeRequests.config.tenant_for = ->(_actor) {}

      expect(create.tenant).to be_nil
    end

    it "is not consulted at all when unset, which is the default" do
      ChangeRequests.config.tenant_for = nil

      expect(create.tenant).to be_nil
    end
  end

  describe "validate!" do
    it "refuses a tenant_for that is not callable" do
      ChangeRequests.config.tenant_for = "organization"

      expect(ChangeRequests.config.problems.join).to include("tenant_for")
    end

    it "refuses a tenant_for taking the wrong number of arguments" do
      ChangeRequests.config.tenant_for = ->(_actor, _extra) {}

      expect(ChangeRequests.config.problems.join).to include("tenant_for")
    end

    it "refuses a visible_scope that is not callable" do
      ChangeRequests.config.visible_scope = :everything

      expect(ChangeRequests.config.problems.join).to include("visible_scope")
    end

    it "refuses a visible_scope taking the wrong number of arguments" do
      ChangeRequests.config.visible_scope = ->(_scope) {}

      expect(ChangeRequests.config.problems.join).to include("visible_scope")
    end

    it "accepts both unset, which is the default" do
      expect(ChangeRequests.config.problems.grep(/tenant_for|visible_scope/)).to be_empty
    end

    it "accepts a splatted callable, whose arity is the host's business" do
      ChangeRequests.config.visible_scope = ->(*args) { args.first }

      expect(ChangeRequests.config.problems.grep(/visible_scope/)).to be_empty
    end
  end
end
