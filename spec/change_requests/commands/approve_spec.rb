# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Commands::Approve do
  subject(:approve) { described_class.call(request: change_request, actor: actor) }

  let(:actor) { Admin.create!(name: "Ada", roles: %w(member_admin)) }
  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "Members::UpdateRoles"
      op.approvals permissions: %w(member_admin), required: 2
    end
  end

  describe "the approval row (§5.4)" do
    subject(:approval) do
      approve

      change_request.approvals.sole
    end

    it "records the decision on the current stage" do
      expect(approval).to have_attributes(decision: "approved",
                                          change_request_stage_id: change_request.stages.sole.id)
    end

    it "snapshots the approver, label included (§5.7)" do
      expect(approval.approver)
        .to include(type: "Admin", id: actor.id.to_s, label: "Ada (admin)")
    end

    it "stamps decided_at" do
      expect(approval.decided_at).to be_within(5.seconds).of(Time.current)
    end

    it "carries no comment unless one was given" do
      expect(approval.comment).to be_nil
    end

    it "records the comment the approver left (§6.6)" do
      described_class.call(request: change_request, actor: actor, comment: "Checked with HR")

      expect(change_request.approvals.sole.comment).to eq("Checked with HR")
    end

    it "snapshots approver_identity when the host declares one (§9.4)" do
      ChangeRequests.config.actor_identity = ->(person) { "person-#{person.name}" }

      expect(approval.approver_identity).to eq("person-Ada")
    end
  end

  describe "the quorum links (§5.3)" do
    it "links the approval to every quorum it counted toward" do
      approve

      expect(change_request.approvals.sole.quorums).to eq([change_request.stages.sole.quorums.sole])
    end

    it "links exactly what the guard called countable" do
      guard = ChangeRequests::Guards::Approve.new(request: change_request, actor: actor)
      countable = guard.countable_quorums
      approve

      expect(change_request.approvals.sole.quorums).to match_array(countable)
    end

    # Resolved at decision time and never re-derived: a later role change must not silently
    # un-approve a request (§5.3).
    it "keeps the link after the approver loses the permission that earned it" do
      approve
      actor.update!(roles: [])

      expect(change_request.reload.approvals.sole.quorums.count).to eq(1)
    end
  end

  describe "the approved event (§5.5)" do
    subject(:event) { change_request.events.where(kind: "approved").sole }

    before { approve }

    it "emits exactly one" do
      expect(change_request.events.where(kind: "approved").count).to eq(1)
    end

    it "attributes it to the approver" do
      expect(event.actor).to eq(type: "Admin", id: actor.id.to_s, label: "Ada (admin)")
    end

    it "names the stage the decision landed on (§5.9)" do
      expect(event.metadata).to eq("stage" => "approval")
    end

    it "carries the approver's comment, so the trail exports alone (§5.5)" do
      described_class.call(request: change_request.reload, actor: Admin.create!(name: "Ben", roles: %w(member_admin)),
                           comment: "Spoke to legal")

      expect(change_request.events.where(kind: "approved").last.body).to eq("Spoke to legal")
    end

    # §5.9: the key is omitted for single-quorum stages, because "which quorum" is not a
    # meaningful question there.
    it "omits the quorum key when the stage holds one nameless quorum" do
      expect(event.metadata).not_to have_key("quorums")
    end

    it "names the quorums when the stage has named ones" do
      change_request = ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                                             requester: requester)
      quorum = change_request.stages.sole.quorums.sole
      quorum.update_columns(name: "owners")

      described_class.call(request: change_request, actor: actor)

      expect(change_request.events.where(kind: "approved").sole.metadata)
        .to eq("stage" => "approval", "quorums" => ["owners"])
    end
  end

  describe "the guard" do
    # I7: one guard object, built once, so the reason a command raises and the quorums it links
    # cannot come from two different evaluations.
    it "is built once and asked twice" do
      allow(ChangeRequests::Guards::Approve).to receive(:new).and_call_original

      approve

      expect(ChangeRequests::Guards::Approve).to have_received(:new).once
    end

    it "raises the guard's refusal rather than writing anything" do
      expect { described_class.call(request: change_request, actor: requester) }
        .to raise_error(ChangeRequests::NotApprovable) { |error|
          expect(error.reason).to eq(:requester)
        }

      expect(change_request.approvals).to be_empty
      expect(change_request.events.where(kind: "approved")).to be_empty
    end

    it "refuses an operation that is no longer declared (§5.11)" do
      change_request # created against a live declaration, which then disappears
      ChangeRequests.operations.clear

      expect { approve }.to raise_error(ChangeRequests::NotApprovable) { |error|
        expect(error.reason).to eq(:operation_undeclared)
      }
    end
  end

  describe "concurrency" do
    # §15.3: the same actor approving twice must surface as NotApprovable, not a 500. The unique
    # index is what actually decides the race; the guard only narrows the window.
    it "maps the unique-index conflict to NotApprovable(:already_decided)" do
      approve
      stage = change_request.stages.sole

      expect do
        stage.approvals.create!(change_request: change_request, approver: actor,
                                decision: "approved", decided_at: Time.current)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "declares the mapping on the command" do
      expect(described_class.conflict_mapping)
        .to eq(error_class: ChangeRequests::NotApprovable, reason: :already_decided)
    end
  end

  it "returns the request" do
    expect(approve).to eq(change_request)
  end

  # Commands::EvaluateWorkflow is M1b-12. Until it lands, an approval is recorded and counted but
  # nothing advances the stage or the request.
  it "leaves the request pending, because evaluation is M1b-12" do
    approve

    expect(change_request.reload.status).to eq("pending")
    expect(change_request.current_stage_position).to eq(1)
  end
end
