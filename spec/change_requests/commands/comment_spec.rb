# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Commands::Comment do
  subject(:comment) do
    described_class.call(request: change_request, actor: actor, body: "Waiting on legal")
  end

  let(:actor) { Admin.create!(name: "Ada", roles: %w(member_admin)) }
  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-12"
      op.service = "Members::UpdateRoles"
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
    end
  end

  describe "the commented event (§5.5)" do
    it "returns the event it wrote" do
      expect(comment).to be_a(ChangeRequests::Event)
      expect(comment.kind).to eq("commented")
    end

    it "carries the body" do
      expect(comment.body).to eq("Waiting on legal")
    end

    it "attributes it to whoever commented" do
      expect(comment.actor).to eq(type: "Admin", id: actor.id.to_s, label: "Ada (admin)")
    end

    it "carries no metadata - a comment is about the request, not a stage" do
      expect(comment.metadata).to eq({})
    end

    it "stamps the version in force" do
      expect(comment.operation_version).to eq("2026-09-12")
    end
  end

  # It writes an event and nothing else, which is what keeps the terminal-state guard out of the way.
  describe "what it does not touch" do
    it "leaves the request's status alone" do
      change_request.update!(status: "successful")

      expect { comment }.not_to(change { change_request.reload.status })
    end

    it "leaves the stages and approvals alone" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: actor)

      expect { described_class.call(request: change_request.reload, actor: requester, body: "Noted") }
        .not_to(change { [change_request.reload.approvals.count, change_request.stages.sole.status] })
    end
  end

  # The acceptance.
  describe "permitted always (§7.2)" do
    it "comments on a successful request" do
      change_request.update!(status: "successful")

      expect(comment.kind).to eq("commented")
    end

    it "comments on a canceled request" do
      change_request.update!(status: "canceled")

      expect(comment.kind).to eq("commented")
    end

    it "comments on a request whose operation has been removed from the registry (§5.11)" do
      change_request
      ChangeRequests.operations.clear

      expect(comment.kind).to eq("commented")
    end

    # The request holds the version it was created under, and with no live declaration that is the
    # only version there is to record - the disappearance is what the note is probably about.
    it "stamps the request's creation-time version when the operation is gone" do
      change_request
      ChangeRequests.operations.clear

      expect(comment.operation_version).to eq(change_request.operation_version)
    end
  end

  describe "the mandatory body" do
    it "raises NotAuthorized(:body_required) for a blank one" do
      expect { described_class.call(request: change_request, actor: actor, body: "   ") }
        .to raise_error(ChangeRequests::NotAuthorized) { |error|
          expect(error.reason).to eq(:body_required)
        }
    end

    it "raises for nil" do
      expect { described_class.call(request: change_request, actor: actor, body: nil) }
        .to raise_error(ChangeRequests::NotAuthorized) { |error|
          expect(error.reason).to eq(:body_required)
        }
    end

    it "is required at the call site, so it cannot be forgotten silently" do
      expect { described_class.call(request: change_request, actor: actor) }
        .to raise_error(ArgumentError, /body/)
    end

    it "writes no event when it refuses" do
      expect { described_class.call(request: change_request, actor: actor, body: nil) }
        .to raise_error(ChangeRequests::NotAuthorized)

      expect(change_request.events.where(kind: "commented")).to be_empty
    end

    it "reports the authorization failure first" do
      expect do
        described_class.call(request: change_request, actor: Admin.create!(name: "Sam"), body: nil)
      end.to raise_error(ChangeRequests::NotAuthorized) { |error|
        expect(error.reason).to eq(:not_permitted)
      }
    end
  end

  describe "the guard" do
    it "raises NotAuthorized for an actor who is neither requester nor approver" do
      expect do
        described_class.call(request: change_request, actor: Admin.create!(name: "Sam"), body: "Hi")
      end.to raise_error(ChangeRequests::NotAuthorized) { |error|
        expect(error.reason).to eq(:not_permitted)
      }

      expect(change_request.events.where(kind: "commented")).to be_empty
    end
  end

  it "records several comments in order" do
    comment
    described_class.call(request: change_request.reload, actor: requester, body: "Legal replied")

    expect(change_request.events.where(kind: "commented").order(:occurred_at).map(&:body))
      .to eq(["Waiting on legal", "Legal replied"])
  end
end
