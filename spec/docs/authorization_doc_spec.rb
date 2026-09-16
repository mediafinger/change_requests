# frozen_string_literal: true

require "rails_helper"

# docs/04_authorization.md, held to the code so it cannot rot.
#
# The Pundit and ActionPolicy recipes are **extracted from the document and run**, against stand-ins
# shaped like each library's real API. Neither gem is a dependency, and the recipes must not become
# one - so what is proven here is the gem's side of the contract: that the lambda each recipe writes
# receives what the document says, and that a guard acts on its answer. A doc edit that breaks a
# recipe reddens this spec.
RSpec.describe "docs/04_authorization.md" do # rubocop:disable RSpec/DescribeClass
  let(:document) { File.read(File.expand_path("../../docs/04_authorization.md", __dir__)) }

  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end
  # What a host writes, and what both libraries resolve: a policy with an approve? rule.
  let(:policy_class) do
    Class.new do
      attr_reader :record, :user

      def initialize(record, user:)
        @record = record
        @user   = user
      end

      def approve?
        user.roles.include?("member_admin")
      end
    end
  end

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-16"
      op.service = "Members::UpdateRoles"
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
    end
  end

  # The ```ruby block following `<!-- recipe: name -->`. A marker rather than a heading, so a
  # heading reworded for readability does not silently unhook the spec.
  def recipe(name)
    block = document[/<!-- recipe: #{name} -->\s*```ruby\n(.*?)```/m, 1]

    fail "docs/04 has no recipe marked #{name.inspect}" if block.nil?

    block
  end

  def run_recipe(name)
    ChangeRequests.module_eval(recipe(name), "docs/04_authorization.md (#{name})")
  end

  def reason_for(actor)
    ChangeRequests::Guards::Approve.new(request: change_request, actor: actor).reason
  end

  describe "the Pundit recipe" do
    # `Pundit.policy!(user, record)` resolves "#{record.class}Policy" and instantiates it - the part
    # of Pundit's API the recipe relies on, and nothing else.
    before do
      stub_const("ChangeRequests::RequestPolicy", Class.new(policy_class) do
        def initialize(user, record)
          super(record, user: user)
        end
      end)

      stub_const("Pundit", Module.new do
        def self.policy!(user, record)
          "#{record.class}Policy".constantize.new(user, record)
        end
      end)

      run_recipe("pundit")
    end

    it "admits an actor the policy approves" do
      expect(reason_for(Admin.create!(name: "Ada", roles: %w(member_admin)))).to be_nil
    end

    it "refuses an actor the policy does not" do
      expect(reason_for(Admin.create!(name: "Ben"))).to eq(:not_permitted)
    end

    it "is called with action :approve, which is the only rule the gem asks" do
      actions = []
      ChangeRequests.config.authorization = lambda { |action:, **|
        actions << action

        true
      }

      reason_for(Admin.create!(name: "Ada"))

      expect(actions.uniq).to eq([:approve])
    end
  end

  describe "the ActionPolicy recipe" do
    # `Policy.new(record, user:).apply(:rule)` - the part of ActionPolicy's API the recipe relies on.
    before do
      stub_const("ChangeRequests::RequestPolicy", Class.new(policy_class) do
        def apply(rule)
          public_send(rule)
        end
      end)

      run_recipe("action_policy")
    end

    it "admits an actor the policy approves" do
      expect(reason_for(Admin.create!(name: "Ada", roles: %w(member_admin)))).to be_nil
    end

    it "refuses an actor the policy does not" do
      expect(reason_for(Admin.create!(name: "Ben"))).to eq(:not_permitted)
    end
  end

  # "What the gem still decides for you" - asserted under a policy that says yes to everyone.
  describe "what a replaced policy does not override" do
    before { ChangeRequests.config.authorization = ->(**) { true } }

    it "still refuses a class that may not approve" do
      ChangeRequests.config.actor_types.fetch("Admin").may_approve = false

      expect(reason_for(Admin.create!(name: "Ada"))).to eq(:not_permitted)
    end

    it "still refuses the requester their own request" do
      expect(reason_for(requester)).to eq(:requester)
    end

    it "still refuses a finished request" do
      change_request.update!(status: "canceled")

      expect(reason_for(Admin.create!(name: "Ada"))).to eq(:already_finalized)
    end

    it "still refuses a second decision by the same person" do
      approver = Admin.create!(name: "Ada")
      ChangeRequests.operations["members.update_roles"].workflow do |w|
        w.stage :approval, permissions: %w(member_admin), threshold: 2
      end
      request = ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                                      requester: requester)
      ChangeRequests::Commands::Approve.call(request: request, actor: approver)

      expect(ChangeRequests::Guards::Approve.new(request: request, actor: approver).reason)
        .to eq(:already_decided)
    end

    it "still refuses every guard but Comment, Cancel and Reap once the operation is undeclared" do
      change_request
      ChangeRequests.operations.clear

      expect(reason_for(Admin.create!(name: "Ada"))).to eq(:operation_undeclared)
    end
  end

  # The document's 2x2 table, cell by cell, against the default policy and the dummy app's own
  # actor classes - so the table cannot drift from what Permissions actually does.
  describe "the permission x actor-type table" do
    def eligible?(actor, permission:, actor_type:)
      stage = change_request.stages.sole
      quorum = stage.quorums.create!(position: 2, name: "probe_#{SecureRandom.hex(3)}", threshold: 1)
      quorum.permissions.create!(permission: permission, actor_type: actor_type)

      ChangeRequests::Authorization::Permissions.new.allows?(actor: actor, quorum: quorum)
    end

    let(:editor_user) { User.create!(name: "Uma", email: "uma@example.com", roles: %w(editor)) }
    let(:plain_admin) { Admin.create!(name: "Abe") }
    let(:editor_manager) { Manager.create!(id: "mgr-1", name: "Mo", roles: %w(editor)) }

    {
      %w(editor User) => [true, false, false],
      ["editor", nil] => [true, false, true],
      [nil, "Admin"] => [false, true, false],
    }.each do |(permission, actor_type), (user, admin, manager)|
      describe "(#{permission.inspect}, #{actor_type.inspect})" do
        it "admits a User with editor: #{user}" do
          expect(eligible?(editor_user, permission: permission, actor_type: actor_type)).to be(user)
        end

        it "admits an Admin with no roles: #{admin}" do
          expect(eligible?(plain_admin, permission: permission, actor_type: actor_type)).to be(admin)
        end

        it "admits a Manager with editor: #{manager}" do
          expect(eligible?(editor_manager, permission: permission, actor_type: actor_type)).to be(manager)
        end
      end
    end

    it "refuses the doubly-null row, which is a bug rather than a wildcard" do
      stage = change_request.stages.sole
      quorum = stage.quorums.create!(position: 2, name: "nothing", threshold: 1)

      expect { quorum.permissions.create!(permission: nil, actor_type: nil) }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "what the document asks of a host" do
    it "names neither Pundit nor ActionPolicy as something to install" do
      expect(document).not_to match(/gem\s+["'](pundit|action_policy)["']/)
    end

    it "says in so many words that neither is a dependency" do
      expect(document.squish).to include("Neither is a dependency of this gem")
    end
  end
end
