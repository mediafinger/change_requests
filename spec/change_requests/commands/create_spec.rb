# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Commands::Create do
  subject(:change_request) { described_class.call(**arguments) }

  let(:arguments) { { operation_key: "members.update_roles", requester: requester, payload: payload } }
  let(:requester) { Admin.create!(name: "Ada") }
  let(:payload) { { "member_id" => "42", "roles" => %w(editor) } }

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "Members::UpdateRoles"
      op.approvals permissions: %w(member_admin), required: 2
    end
  end

  describe "the request row (§5.1)" do
    it "snapshots what will be invoked, resolved from the declaration and not from the caller" do
      expect(change_request).to have_attributes(
        operation_key: "members.update_roles",
        operation_version: "2026-09-12",
        service: "Members::UpdateRoles",
        method_name: "call"
      )
    end

    it "starts pending on the first stage" do
      expect(change_request.status).to eq("pending")
      expect(change_request.current_stage_position).to eq(1)
    end

    it "stores the payload as given" do
      expect(change_request.payload).to eq(payload)
    end

    it "snapshots the requester triple, label included (§5.7)" do
      expect(change_request.requester)
        .to include(type: "Admin", id: requester.id.to_s, label: "Ada (admin)")
    end

    it "leaves the tenant columns null when no tenant is passed (§5.1)" do
      expect(change_request.tenant).to be_nil
    end

    it "snapshots a tenant when one is passed" do
      organization = Organization.create!(name: "Acme")

      change_request = described_class.call(**arguments, tenant: organization)

      expect(change_request.tenant).to eq(type: "Organization", id: organization.id.to_s, label: "Acme")
    end

    it "takes max_attempts from the declaration (§5.6)" do
      ChangeRequests.operations["members.update_roles"].max_attempts = 3

      expect(change_request.max_attempts).to eq(3)
    end

    it "leaves expires_at null when the operation never expires" do
      expect(change_request.expires_at).to be_nil
    end

    it "computes expires_at from the declaration's expires_in" do
      ChangeRequests.operations["members.update_roles"].expires_in = 7.days

      expect(change_request.expires_at).to be_within(5.seconds).of(7.days.from_now)
    end

    # §19.13: the request's own id is the idempotency key.
    it "has no idempotency_key column to fill" do
      expect(ChangeRequests::Request.column_names).not_to include("idempotency_key")
    end
  end

  describe "payload_labels" do
    it "is empty when the operation declares no labels" do
      expect(change_request.payload_labels).to eq({})
    end

    # Labels persist even when the objects are deleted, to keep a usable audit trail (§6.4).
    it "snapshots what the declaration's lambda returns, keyed as strings" do
      ChangeRequests.operations["members.update_roles"].payload_labels =
        ->(p) { { member_id: "Member #{p["member_id"]}" } }

      expect(change_request.payload_labels).to eq("member_id" => "Member 42")
    end

    it "receives the payload it was given" do
      seen = nil
      ChangeRequests.operations["members.update_roles"].payload_labels = lambda { |p|
        seen = p

        {}
      }
      change_request

      expect(seen).to eq(payload)
    end
  end

  describe "the payload must be a JSON object (§6.12)" do
    it "defaults to an empty object when none is given" do
      change_request = described_class.call(operation_key: "members.update_roles", requester: requester)

      expect(change_request.payload).to eq({})
    end

    [["an array", []], ["a string", "member_id=42"], ["a number", 7], ["nil", nil]].each do |name, value|
      it "refuses #{name}" do
        expect { described_class.call(**arguments, payload: value) }
          .to raise_error(ChangeRequests::InvalidPayload)
      end
    end

    it "accepts symbol keys, which round-trip through jsonb as strings" do
      change_request = described_class.call(**arguments, payload: { member_id: "42" })

      expect(change_request.reload.payload).to eq("member_id" => "42")
    end
  end

  describe "who may request (§7.2)" do
    it "refuses an actor type that does not declare may_request (§19.4)" do
      ChangeRequests.config.actor_types.fetch("Admin").may_request = false

      expect { change_request }.to raise_error(ChangeRequests::NotAuthorized) { |error|
        expect(error.reason).to eq(:may_not_request)
      }
    end

    # The message comes from the locale file, so it says nothing about `t.may_request` - a
    # configuration key has no business in a flash the requester reads (Q45).
    it "words the refusal for the person being refused" do
      ChangeRequests.config.actor_types.fetch("Admin").may_request = false

      expect { change_request }
        .to raise_error(ChangeRequests::NotAuthorized,
                        "Your kind of account cannot raise change requests.")
    end

    it "refuses an actor whose class is not registered at all (§9.1)" do
      expect { described_class.call(**arguments, requester: Object.new) }
        .to raise_error(ChangeRequests::UnknownActorType)
    end

    it "writes nothing when it refuses" do
      ChangeRequests.config.actor_types.fetch("Admin").may_request = false

      expect { change_request }.to raise_error(ChangeRequests::NotAuthorized)
      expect(ChangeRequests::Request.count).to eq(0)
    end
  end

  describe "the operation must be declared (§5.11, §6.12)" do
    it "refuses an operation key with no live declaration" do
      ChangeRequests.operations.clear

      expect { change_request }.to raise_error(ChangeRequests::UnknownOperation, /members\.update_roles/)
    end

    # An approval gate with no approvers is a misconfiguration, and a request that can never leave
    # `pending` is worse than a loud failure at the call site. M2's verify! catches it at boot.
    it "refuses a declaration with no approvals at all" do
      ChangeRequests.operations.define("orders.refund") do |op|
        op.version = "1"
        op.service = "Orders::Refund"
      end

      expect { described_class.call(operation_key: "orders.refund", requester: requester) }
        .to raise_error(ChangeRequests::ConfigurationError, /orders\.refund.*approvals/m)
    end

    it "refuses a declaration with no dispatch target, rather than failing a NOT NULL" do
      ChangeRequests.operations["members.update_roles"].service = nil

      expect { change_request }.to raise_error(ChangeRequests::ConfigurationError, /service/)
    end

    # One call should fix one round of mistakes, not one mistake per call.
    it "reports both problems at once" do
      ChangeRequests.operations.define("orders.refund") { |op| op.version = "1" }

      expect { described_class.call(operation_key: "orders.refund", requester: requester) }
        .to raise_error(ChangeRequests::ConfigurationError) { |error|
          expect(error.message.lines.grep(/^- /).size).to eq(2)
        }
    end
  end

  describe "materialisation (§5.2, §5.3)" do
    it "writes the stage the declaration describes" do
      stage = change_request.stages.sole

      expect(stage).to have_attributes(position: 1, name: "approval", satisfied_by: "any_quorum",
                                       status: "pending")
    end

    it "writes the quorum, nameless because its stage holds only one (§5.9)" do
      quorum = change_request.stages.sole.quorums.sole

      expect(quorum).to have_attributes(position: 1, name: nil, threshold: 2,
                                        permission_match: "any", status: "pending")
    end

    describe "all four §6.4 op.approvals forms (Q14, moved here from M1b-0)" do
      def quorum_for(**approvals)
        ChangeRequests.operations["members.update_roles"].approvals(**approvals)

        change_request.stages.sole.quorums.sole
      end

      it "(a) permissions: two holders of a permission" do
        quorum = quorum_for(permissions: %w(member_admin), required: 2)

        expect(quorum.threshold).to eq(2)
        expect(quorum.permissions.map { |row| [row.permission, row.actor_type] })
          .to eq([["member_admin", nil]])
        expect(quorum.eligible_actors).to be_empty
      end

      it "(b) actor_type: one actor of a class" do
        quorum = quorum_for(actor_type: "Admin", required: 1)

        expect(quorum.permissions.map { |row| [row.permission, row.actor_type] })
          .to eq([[nil, "Admin"]])
      end

      it "(c) match: one person holding both permissions" do
        quorum = quorum_for(permissions: %w(finance compliance), match: :all, required: 1)

        expect(quorum.permission_match).to eq("all")
        expect(quorum.permissions.map(&:permission)).to contain_exactly("finance", "compliance")
      end

      it "(d) eligible_actors: only these two people" do
        cfo = Admin.create!(name: "Cleo")
        counsel = User.create!(name: "Gene", email: "gene@example.com")

        quorum = quorum_for(eligible_actors: [cfo, counsel], required: 2)

        expect(quorum.permissions).to be_empty
        expect(quorum.eligible_actors.map { |row| [row.actor_type, row.actor_id] })
          .to contain_exactly(["Admin", cfo.id.to_s], ["User", counsel.id.to_s])
      end

      # M1b-0 keeps the actor objects as declared rather than resolving them in an initializer,
      # before the file registering the actor types has necessarily run. This is where they resolve.
      it "refuses a named approver whose class is not registered (§9.1)" do
        ChangeRequests.operations["members.update_roles"].approvals(eligible_actors: [Object.new])

        expect { change_request }.to raise_error(ChangeRequests::UnknownActorType)
      end
    end

    # op.workflow is M2, but the description it will produce is already a public value object, so
    # the materialiser's multi-stage path is provable now.
    describe "a multi-stage workflow" do
      before do
        operation = ChangeRequests.operations["members.update_roles"]
        operation.instance_variable_set(:@workflow, ChangeRequests::Workflow.new([triage, sign_off]))
      end

      let(:triage) do
        ChangeRequests::Workflow::Stage.new(
          name: "triage", position: 1, satisfied_by: :any_quorum,
          quorums: [quorum(name: "support", threshold: 1, permissions: [%w(support)])]
        )
      end

      let(:sign_off) do
        ChangeRequests::Workflow::Stage.new(
          name: "sign_off", position: 2, satisfied_by: :all_quorums,
          quorums: [
            quorum(name: "risk", position: 1, threshold: 1, match: :all,
                   permissions: [%w(risk), %w(compliance)]),
            quorum(name: "money", position: 2, threshold: 2, permissions: [%w(finance Admin)]),
          ]
        )
      end

      def quorum(name:, threshold:, permissions:, position: 1, match: nil)
        ChangeRequests::Workflow::Quorum.new(
          name: name, position: position, threshold: threshold, permission_match: match,
          permissions: permissions.map do |permission, actor_type|
            ChangeRequests::Workflow::Permission.new(permission: permission, actor_type: actor_type)
          end,
          eligible_actors: []
        )
      end

      it "writes the stages in order" do
        expect(change_request.stages.map(&:name)).to eq(%w(triage sign_off))
        expect(change_request.stages.map(&:position)).to eq([1, 2])
      end

      it "carries each stage's satisfied_by" do
        expect(change_request.stages.map(&:satisfied_by)).to eq(%w(any_quorum all_quorums))
      end

      it "writes every quorum under its own stage" do
        expect(change_request.stages.map { |stage| stage.quorums.map(&:name) })
          .to eq([["support"], %w(risk money)])
      end

      it "carries each quorum's threshold and match" do
        money = change_request.stages.last.quorums.find_by(name: "money")
        risk = change_request.stages.last.quorums.find_by(name: "risk")

        expect(money).to have_attributes(threshold: 2, permission_match: "any")
        expect(risk).to have_attributes(threshold: 1, permission_match: "all")
      end

      it "writes the permission rows of each quorum, both axes" do
        risk = change_request.stages.last.quorums.find_by(name: "risk")
        money = change_request.stages.last.quorums.find_by(name: "money")

        expect(risk.permissions.map { |row| [row.permission, row.actor_type] })
          .to contain_exactly(["risk", nil], ["compliance", nil])
        expect(money.permissions.map { |row| [row.permission, row.actor_type] })
          .to eq([%w(finance Admin)])
      end

      it "leaves the request on stage one" do
        expect(change_request.current_stage).to eq(change_request.stages.first)
      end
    end

    # §6.12 point 4. The materialised rows are the frozen snapshot, not a cache of the declaration.
    describe "the snapshot is frozen at creation" do
      it "is unchanged when the declaration's threshold is edited afterwards" do
        change_request
        ChangeRequests.operations["members.update_roles"].approvals(permissions: %w(auditor), required: 9)

        expect(change_request.reload.stages.sole.quorums.sole.threshold).to eq(2)
      end

      it "is unchanged when the declaration is removed entirely (§5.11)" do
        change_request
        ChangeRequests.operations.clear

        expect(change_request.reload.stages.sole.quorums.sole.permissions.map(&:permission))
          .to eq(["member_admin"])
      end

      it "keeps the version it was created under, not the version in force now" do
        change_request
        ChangeRequests.operations["members.update_roles"].version = "2026-12-01"

        expect(change_request.reload.operation_version).to eq("2026-09-12")
      end
    end

    it "writes the whole graph in one transaction, or none of it" do
      ChangeRequests.operations["members.update_roles"].approvals(eligible_actors: [Object.new])

      expect { change_request }.to raise_error(ChangeRequests::UnknownActorType)
      expect(ChangeRequests::Request.count).to eq(0)
      expect(ChangeRequests::Stage.count).to eq(0)
    end
  end

  describe "the requested event (§5.5)" do
    subject(:event) { change_request.events.sole }

    it "records one event, through Commands::Base#emit" do
      expect(event.kind).to eq("requested")
    end

    it "attributes it to the requester" do
      expect(event.actor).to eq(type: "Admin", id: requester.id.to_s, label: "Ada (admin)")
    end

    it "stamps the version in force, which at creation is the request's own" do
      expect(event.operation_version).to eq("2026-09-12")
    end
  end

  # §9.4: (approver_type, approver_id) is airtight within one actor class and blind across them.
  # Without this snapshot, requesting as User#99 and approving as Admin#7 defeats four-eyes silently.
  describe "requester_identity (§9.4)" do
    it "is null when the host declares no shared identity" do
      expect(change_request.requester_identity).to be_nil
    end

    it "snapshots what config.actor_identity returns" do
      ChangeRequests.config.actor_identity = ->(person) { "person-#{person.name}" }

      expect(change_request.requester_identity).to eq("person-Ada")
    end

    it "reaches the guards through the requester reference, so same_person? can use it" do
      ChangeRequests.config.actor_identity = ->(person) { person.name }

      expect(change_request.requester[:identity]).to eq("Ada")
    end

    it "is a creation-time fact and cannot be rewritten (§5.1)" do
      change_request.requester_identity = "someone-else"

      expect { change_request.save! }.to raise_error(ChangeRequests::ReadonlyAttribute, /requester_identity/)
    end
  end
end
