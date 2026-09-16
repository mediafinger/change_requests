# frozen_string_literal: true

require "rails_helper"

module PresenterProbes
  class Roles
    def self.call(**); end
  end

  class Raises
    def self.call(**)
      fail("Timeout calling provider")
    end
  end
end

RSpec.describe ChangeRequests::RequestPresenter do
  subject(:presenter) { described_class.new(change_request, actor: nil) }

  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:approver) { Admin.create!(name: "Ada", roles: %w(member_admin)) }
  let(:organization) { Organization.create!(name: "Acme") }
  let(:payload) { { "roles" => %w(editor), "member_id" => "42", "note" => "urgent" } }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester,
                                          payload: payload)
  end

  def declare(service: "PresenterProbes::Roles", **options)
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-17"
      op.service = service
      op.method_name = :call
      op.expires_in = options[:expires_in] if options[:expires_in]
      op.override(permissions: %w(security_officer)) if options[:override]
      op.payload_labels = options[:payload_labels] if options[:payload_labels]
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: options.fetch(:threshold, 1) }
    end
  end

  def approve_and_execute
    ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)
    ChangeRequests::Commands::Execute.call(request: change_request, actor: approver)
  end

  before { declare }

  describe "identity" do
    it "reads the operation from the request's own columns" do
      expect([presenter.operation_key, presenter.operation_version, presenter.operation_label])
        .to eq(["members.update_roles", "2026-09-17", "PresenterProbes::Roles.call"])
    end

    # §5.12: a historical request renders identically once its declaration is gone.
    it "renders the same once the operation is no longer declared" do
      change_request
      ChangeRequests.operations.clear

      expect([presenter.operation_key, presenter.operation_label, presenter.status.key, presenter.payload_fields.size])
        .to eq(["members.update_roles", "PresenterProbes::Roles.call", :pending, 3])
    end

    it "keeps the actor and the routes it was given" do
      routes = Object.new

      expect(described_class.new(change_request, actor: approver, routes: routes))
        .to have_attributes(actor: approver, routes: routes, resolve_actors?: true)
    end
  end

  describe "actors" do
    it "answers the requester as an ActorRef" do
      expect(presenter.requester).to have_attributes(type: "User", id: requester.id, label: "Rita")
    end

    it "has no executer or tenant until there is one" do
      expect([presenter.executer, presenter.tenant]).to eq([nil, nil])
    end

    it "answers the executer once someone executed it" do
      approve_and_execute

      expect(described_class.new(change_request.reload, actor: nil).executer)
        .to have_attributes(type: "Admin", label: "Ada (admin)")
    end

    it "answers the tenant" do
      tenanted = ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester,
                                                       tenant: organization)

      expect(described_class.new(tenanted, actor: nil).tenant).to have_attributes(type: "Organization", label: "Acme")
    end

    describe "a deleted actor" do
      before do
        change_request
        requester.destroy!
      end

      it "degrades to the snapshot rather than raising (§11)" do
        expect(presenter.requester).to have_attributes(deleted?: true, label: "Rita", record: nil)
      end

      it "has no path" do
        expect(presenter.requester.path(Object.new)).to be_nil
      end
    end

    describe "resolve_actors: true" do
      let(:tenanted) do
        ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester,
                                              tenant: organization).tap do |request|
          ChangeRequests::Commands::Approve.call(request: request, actor: approver)
          ChangeRequests::Commands::Execute.call(request: request, actor: approver)
        end.reload
      end

      # User, Admin and Organization: one query each, however many of the three are asked for.
      it "resolves all three refs together, one query per actor type" do
        presenter = described_class.new(tenanted, actor: nil)

        expect { presenter.requester.record }.to issue_queries(3)
        expect { [presenter.executer.record, presenter.tenant.record, presenter.requester.label] }
          .to issue_no_queries
      end
    end

    describe "resolve_actors: false" do
      subject(:presenter) { described_class.new(tenanted, actor: nil, resolve_actors: false) }

      let(:tenanted) do
        ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester,
                                              tenant: organization).tap do |request|
          ChangeRequests::Commands::Approve.call(request: request, actor: approver)
          ChangeRequests::Commands::Execute.call(request: request, actor: approver)
        end.reload
      end

      before { ChangeRequests.config.actor_label_strategy = :live }

      # §11's fast path, and the only one once an actor class is gone: every label is on the row.
      it "renders every actor with no query at all, even under :live labels" do
        tenanted
        requester.update!(name: "Renamed")

        expect do
          refs = [presenter.requester, presenter.executer, presenter.tenant]

          expect(refs.map(&:label)).to eq(["Rita", "Ada (admin)", "Acme"])
          expect(refs.map { |ref| [ref.deleted?, ref.path(Object.new)] }).to all(eq([false, nil]))
        end.to issue_no_queries
      end

      it "claims nothing about a deleted actor, since nobody looked" do
        tenanted
        requester.destroy!

        expect(presenter.requester).to have_attributes(deleted?: false, label: "Rita")
      end
    end
  end

  describe "payload" do
    # jsonb does not keep insertion order, so alphabetical is the only explicable one (§5.12).
    it "orders fields alphabetically by key" do
      expect(presenter.payload_fields.map(&:key)).to eq(%w(member_id note roles))
    end

    it "is a whole structure, comparable in one expectation" do
      expect(presenter.payload_fields).to eq(
        [
          ChangeRequests::Value::Field.new(key: "member_id", value: "42"),
          ChangeRequests::Value::Field.new(key: "note", value: "urgent"),
          ChangeRequests::Value::Field.new(key: "roles", value: %w(editor)),
        ]
      )
    end

    it "labels each key through the translation fallback" do
      expect(presenter.payload_fields.map(&:label)).to eq(%w(Member Note Roles))
    end

    it "translates a key's label when the host wrote one" do
      with_translations("change_requests.fields.member_id" => "Team member")

      expect(presenter.payload_fields.first.label).to eq("Team member")
    end

    describe "sparse payload_labels" do
      before { declare(payload_labels: ->(p) { { member_id: "Ada Lovelace (#{p["member_id"]})", ghost: "unused" } }) }

      it "renders the declared label where there is one and the raw value otherwise" do
        expect(presenter.payload_fields.map(&:value)).to eq(["Ada Lovelace (42)", "urgent", %w(editor)])
      end

      it "ignores a label for a key the payload does not have" do
        expect(presenter.payload_fields.map(&:key)).not_to include("ghost")
      end
    end

    it "respects a declared empty label, which was the host's choice" do
      declare(payload_labels: ->(_) { { note: "" } })

      expect(presenter.payload_fields.find { |field| field.key == "note" }.value).to eq("")
    end

    describe "payload_preview" do
      it "is the first three fields by default" do
        payload["zone"] = "eu"

        expect(presenter.payload_preview.map(&:key)).to eq(%w(member_id note roles))
      end

      it "honours config.payload_preview_limit" do
        ChangeRequests.config.payload_preview_limit = 1

        expect(presenter.payload_preview).to eq([presenter.payload_fields.first])
      end

      it "is empty at a limit of zero" do
        ChangeRequests.config.payload_preview_limit = 0

        expect(presenter.payload_preview).to eq([])
      end

      it "is every field when there are fewer than the limit" do
        ChangeRequests.config.payload_preview_limit = 10

        expect(presenter.payload_preview).to eq(presenter.payload_fields)
      end
    end

    describe "an empty payload" do
      let(:payload) { {} }

      it "has no fields and no preview" do
        expect([presenter.payload_fields, presenter.payload_preview]).to eq([[], []])
      end
    end

    it "costs no query" do
      change_request

      expect { presenter.payload_fields && presenter.payload_preview }.to issue_no_queries
    end
  end

  describe "status" do
    def status_of(request)
      described_class.new(request.reload, actor: nil).status
    end

    it "declares a tone for exactly the statuses a request can have" do
      expect(described_class::STATUS_TONES.keys).to match_array(ChangeRequests::Request::STATUSES.map(&:to_sym))
    end

    it "uses only tones from the closed set" do
      expect(described_class::STATUS_TONES.values - ChangeRequests::Value::TONES).to be_empty
    end

    it "is a pending request, neutral and without a tooltip" do
      expect(presenter.status).to eq(ChangeRequests::Value::Status.new(key: :pending, tone: :neutral))
    end

    it "labels through the translation fallback" do
      with_translations("change_requests.statuses.pending" => "Awaiting approval")

      expect(presenter.status.label).to eq("Awaiting approval")
    end

    it "costs no query when the status has nothing to say" do
      change_request

      expect { presenter.status }.to issue_no_queries
    end

    it "is approved, primary" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)

      expect(status_of(change_request)).to have_attributes(key: :approved, tone: :primary, tooltip: nil)
    end

    it "is successful, success" do
      approve_and_execute

      expect(status_of(change_request)).to have_attributes(key: :successful, tone: :success, tooltip: nil)
    end

    it "is rejected, danger" do
      ChangeRequests::Commands::Reject.call(request: change_request, actor: approver, reason: "No")

      expect(status_of(change_request)).to have_attributes(key: :rejected, tone: :danger, tooltip: nil)
    end

    it "is failed, danger, naming the last attempt's error" do
      declare(service: "PresenterProbes::Raises")
      expect { approve_and_execute }.to raise_error(ChangeRequests::TargetFailed)

      expect(status_of(change_request)).to have_attributes(key: :failed, tone: :danger,
                                                           tooltip: "Timeout calling provider")
    end

    it "is canceled, neutral, giving the reason" do
      ChangeRequests::Commands::Cancel.call(request: change_request, actor: requester, reason: "No longer needed")

      expect(status_of(change_request)).to have_attributes(key: :canceled, tone: :neutral,
                                                           tooltip: "No longer needed")
    end

    it "gives the gem's own reason for a request canceled as undeclared" do
      change_request
      ChangeRequests.operations.clear
      ChangeRequests::Commands::CancelUndeclared.call(request: change_request)

      expect(status_of(change_request).tooltip).to include("no longer declared")
    end

    describe "expired" do
      before do
        declare(expires_in: 7.days)
        change_request.update_columns(expires_at: Time.utc(2026, 9, 10, 12, 0, 0))
        ChangeRequests::Commands::Expire.call(request: change_request.reload)
      end

      it "is a warning naming the deadline in UTC" do
        expect(status_of(change_request)).to have_attributes(key: :expired, tone: :warning,
                                                             tooltip: "Expired at 2026-09-10T12:00:00Z")
      end

      it "translates the tooltip" do
        with_translations("change_requests.statuses.expired_tooltip" => "Ran out at %{expires_at}")

        expect(status_of(change_request).tooltip).to eq("Ran out at 2026-09-10T12:00:00Z")
      end
    end

    describe "after an override (§8.1)" do
      let(:officer) { Manager.create!(id: "mgr-1", name: "Olive", roles: %w(security_officer)) }

      before { declare(override: true, threshold: 2) }

      it "is a warning naming the shortfall and the reason" do
        ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)
        ChangeRequests::Commands::Override.call(request: change_request, actor: officer, reason: "Outage")

        expect(status_of(change_request)).to have_attributes(
          key: :successful, tone: :warning,
          tooltip: "Executed without approval: 1 of 2 approvals. Reason: Outage"
        )
      end

      it "stays danger when the overridden run failed, naming the error" do
        declare(service: "PresenterProbes::Raises", override: true, threshold: 2)

        expect do
          ChangeRequests::Commands::Override.call(request: change_request, actor: officer, reason: "Outage")
        end.to raise_error(ChangeRequests::TargetFailed)

        expect(status_of(change_request)).to have_attributes(key: :failed, tone: :danger,
                                                             tooltip: "Timeout calling provider")
      end
    end

    it "is executing, primary" do
      change_request.update_columns(status: "executing")

      expect(status_of(change_request)).to have_attributes(key: :executing, tone: :primary, tooltip: nil)
    end

    # M5-6 preloads; a presenter over a preloaded request must not ask again.
    it "reads preloaded events rather than querying for the tooltip" do
      ChangeRequests::Commands::Cancel.call(request: change_request, actor: requester, reason: "No longer needed")
      preloaded = ChangeRequests::Request.includes(:events, :attempts).find(change_request.id)

      expect { described_class.new(preloaded, actor: nil).status.tooltip }.to issue_no_queries
    end
  end
end
