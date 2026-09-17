# frozen_string_literal: true

require "rails_helper"

module ActionProbes
  class Target
    def self.call(**); end
  end

  COMMANDS = {
    approve: ->(request, actor) { ChangeRequests::Commands::Approve.call(request:, actor:) },
      unapprove: ->(request, actor) { ChangeRequests::Commands::Unapprove.call(request:, actor:) },
      reject: ->(request, actor) { ChangeRequests::Commands::Reject.call(request:, actor:, reason: "No") },
      execute: ->(request, actor) { ChangeRequests::Commands::Execute.call(request:, actor:) },
      execute_override: ->(request, actor) { ChangeRequests::Commands::Override.call(request:, actor:, reason: "Outage") },
      cancel: ->(request, actor) { ChangeRequests::Commands::Cancel.call(request:, actor:, reason: "No") },
      comment: ->(request, actor) { ChangeRequests::Commands::Comment.call(request:, actor:, body: "Note") },
  }.freeze
end

# M5-4: every action is computed from the guard its command enforces with, so a disabled button and a
# raised error cannot disagree (§7). Asserted by running both.
RSpec.describe ChangeRequests::RequestPresenter, "#actions" do
  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:approver) { Admin.create!(name: "Ada", roles: %w(member_admin)) }
  let(:outsider) { Admin.create!(name: "Otto") }
  let(:officer) { Manager.create!(id: "mgr-1", name: "Olive", roles: %w(security_officer)) }

  def declare(override: nil)
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-17"
      op.service = "ActionProbes::Target"
      op.override(**override) if override
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
    end
  end

  def build(status)
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
                                    .tap { |request| request.update_columns(status: status) }
                                    .reload
  end

  def actions_for(request, actor, **)
    described_class.new(request, actor: actor, **).actions
  end

  # [enabled, message] as the command answers, the writes rolled back.
  def command_answer(name, request, actor)
    answer = [true, nil]

    ActiveRecord::Base.transaction(requires_new: true) do
      ActionProbes::COMMANDS.fetch(name).call(request, actor)
    rescue ChangeRequests::NotAuthorized, ChangeRequests::TransitionError => e
      answer = [false, e.message]
    ensure
      fail ActiveRecord::Rollback
    end

    answer
  end

  describe "agreeing with the commands" do
    before { declare(override: { permissions: %w(security_officer), require_reason: true }) }

    roles = %i(requester approver outsider officer)

    ChangeRequests::Request::STATUSES.each do |status|
      roles.each do |role|
        it "answers as every command does for a #{status} request and its #{role}" do
          actor = public_send(role)
          request = build(status)
          actions = actions_for(request, actor)

          answers = actions.to_h { |action| [action.name, command_answer(action.name, build(status), actor)] }

          expect(actions.to_h { |action| [action.name, [action.enabled, action.reason]] }).to eq(answers)
        end
      end
    end

    it "agrees once an approver has decided, which Unapprove is the one guard to permit" do
      request = build("pending")
      ChangeRequests::Commands::Approve.call(request:, actor: approver)
      unapprove = actions_for(request.reload, approver).find { |action| action.name == :unapprove }

      expect([unapprove.enabled, unapprove.reason]).to eq([true, nil])
    end

    it "agrees on an undeclared operation, where only Cancel and Comment stay open" do
      request = build("pending")
      ChangeRequests.operations.clear

      expect(actions_for(request, requester).select(&:enabled).map(&:name)).to eq(%i(cancel comment))
    end
  end

  describe "the list" do
    before { declare }

    it "offers every transition, in a fixed order, when no override is declared" do
      expect(actions_for(build("pending"), approver).map(&:name))
        .to eq(%i(approve unapprove reject execute cancel comment))
    end

    it "labels, tones and asks for reasons as the commands require" do
      expect(actions_for(build("pending"), approver).map { |a| [a.name, a.label, a.tone, a.requires_reason, a.http_method] })
        .to eq([[:approve, "Approve", :primary, false, :post],
                [:unapprove, "Take back approval", :neutral, false, :post],
                [:reject, "Reject", :danger, true, :post],
                [:execute, "Execute", :primary, false, :post],
                [:cancel, "Cancel request", :warning, true, :post],
                [:comment, "Comment", :neutral, false, :post]])
    end

    it "gives a disabled action the translated sentence the command would raise" do
      approve = actions_for(build("approved"), approver).first

      expect([approve.enabled, approve.reason]).to eq([false, "This request is no longer open for decisions."])
    end

    it "is empty with no actor, since every guard asks who is acting" do
      expect(actions_for(build("pending"), nil)).to eq([])
    end

    it "builds each guard once and shares it" do
      presenter = described_class.new(build("pending"), actor: approver)

      first = presenter.guard(:approve)

      expect(presenter.guard(:approve)).to be(first)
      expect(presenter.actions.first.enabled).to eq(first.allowed?)
      expect(presenter.guard(:execute_override)).to be_nil
    end
  end

  describe "execute_override (§8.1)" do
    it "is absent when the operation declares no override" do
      declare

      expect(actions_for(build("pending"), officer).map(&:name)).not_to include(:execute_override)
    end

    it "is absent once the operation is no longer declared" do
      declare(override: { permissions: %w(security_officer) })
      request = build("pending")
      ChangeRequests.operations.clear

      expect(actions_for(request, officer).map(&:name)).not_to include(:execute_override)
    end

    describe "when declared" do
      subject(:override) { actions_for(build("pending"), officer).find { |action| action.name == :execute_override } }

      before { declare(override: { permissions: %w(security_officer), require_reason: true }) }

      it "is a separate, dangerous, confirmed action next to Execute" do
        expect(override).to have_attributes(tone: :danger, enabled: true, requires_reason: true,
                                            confirm: "This bypasses 2 required approvals. Continue?")
      end

      it "counts approvals that already landed out of the confirmation" do
        request = build("pending")
        ChangeRequests::Commands::Approve.call(request:, actor: approver)

        expect(actions_for(request.reload, officer).find { |action| action.name == :execute_override }.confirm)
          .to eq("This bypasses 1 required approval. Continue?")
      end

      # "This bypasses 0 required approvals" is untrue of a request with nothing left to bypass.
      it "asks for no confirmation when nothing would be bypassed" do
        request = build("pending")
        2.times { |i| ChangeRequests::Commands::Approve.call(request:, actor: Admin.create!(name: "A#{i}", roles: %w(member_admin))) }

        expect(actions_for(request.reload, officer).find { |action| action.name == :execute_override })
          .to have_attributes(enabled: false, confirm: nil)
      end

      it "is labelled as what it is, never as Execute" do
        expect(override.label).to eq("Execute without approval")
      end

      it "takes require_reason from the declaration" do
        declare(override: { permissions: %w(security_officer), require_reason: false })

        expect(actions_for(build("pending"), officer).find { |a| a.name == :execute_override }.requires_reason)
          .to be(false)
      end
    end
  end

  describe "paths" do
    before { declare }

    it "is nil for every action with no routes, and raises nothing" do
      expect(actions_for(build("pending"), approver).map(&:path)).to all(be_nil)
    end

    it "asks the injected routes for each member path" do
      request = build("pending")
      routes = Class.new do
        %i(approve unapprove reject execute cancel comment).each do |name|
          define_method(:"#{name}_request_path") { |record| "/change_requests/requests/#{record.id}/#{name}" }
        end
      end.new

      expect(actions_for(request, approver, routes: routes).to_h { |action| [action.name, action.path] })
        .to eq(%i(approve unapprove reject execute cancel comment).to_h { |name|
          [name, "/change_requests/requests/#{request.id}/#{name}"]
        })
    end

    # A host drawing only some routes (M6a-2): an action whose route is absent has no path.
    it "is nil where the routes do not draw that action" do
      routes = Class.new do
        def approve_request_path(_)
          "/approve"
        end
      end.new

      expect(actions_for(build("pending"), approver, routes: routes).to_h { |a| [a.name, a.path] })
        .to include(approve: "/approve", reject: nil)
    end

    it "posts an override to Execute's path" do
      declare(override: { permissions: %w(security_officer) })
      routes = Class.new do
        def execute_request_path(_)
          "/execute"
        end
      end.new

      expect(actions_for(build("pending"), officer, routes: routes).find { |a| a.name == :execute_override }.path)
        .to eq("/execute")
    end
  end
end
