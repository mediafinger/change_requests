# frozen_string_literal: true

require "rails_helper"

module CollectionProbes
  class Target
    def self.call(**); end
  end

  HOST_TABLES = /\b(users|admins|managers|organizations)\b/
end

# M5-6: the collection owns eager loading, so an index page's N+1 is fixed once (§11).
RSpec.describe ChangeRequests::CollectionPresenter do
  let(:organization) { Organization.create!(name: "Acme") }
  let(:approver) { Admin.create!(name: "Ada", roles: %w(member_admin)) }

  before do
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-17"
      op.service = "CollectionProbes::Target"
      op.payload_labels = ->(payload) { { member_id: "Member #{payload["member_id"]}" } }
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
    end
  end

  # Requesters across three actor classes; every third executed, so executers and timelines vary too.
  def page_of(count)
    Array.new(count) do |index|
      requester = [
        -> { User.create!(name: "User #{index}", email: "u#{index}@example.com") },
        -> { Admin.create!(name: "Admin #{index}") },
        -> { Manager.create!(id: "mgr-#{index}", name: "Manager #{index}") },
      ][index % 3].call
      request = ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester,
                                                      tenant: organization, payload: { "member_id" => index.to_s })
      next request unless (index % 3).zero?

      ChangeRequests::Commands::Approve.call(request: request, actor: approver)
      ChangeRequests::Commands::Execute.call(request: request, actor: approver)
      request
    end
  end

  def scope_of(requests)
    ChangeRequests::Request.where(id: requests.map(&:id)).order(:created_at)
  end

  # What an index row and a show page read, everything but actions.
  def render(collection)
    collection.map do |presenter|
      [presenter.operation_label, presenter.requester.label, presenter.executer&.label, presenter.tenant&.label,
       presenter.status, presenter.payload_preview, presenter.stages,
       presenter.timeline.map { |entry| [entry.label, entry.actor.label, entry.actor.deleted?] }]
    end
  end

  describe "a page of 25 requests across three actor classes" do
    let!(:requests) { page_of(25) }

    # 1 requests + 6 progress (stages, quorums, permissions, eligible actors, links, approvals) + events +
    # attempts, then one per host class: User, Admin, Manager, Organization.
    it "issues 13 queries, however many rows" do
      expect { render(described_class.new(scope_of(requests), actor: nil)) }.to issue_queries(13)
    end

    it "issues the same 13 for a page of 5" do
      expect { render(described_class.new(scope_of(requests.first(5)), actor: nil)) }.to issue_queries(13)
    end

    it "issues one query per host class, never one per row" do
      queries = QueryCounter.capture { render(described_class.new(scope_of(requests), actor: nil)) }

      expect(queries.grep(CollectionProbes::HOST_TABLES).size).to eq(4)
    end

    it "issues none against host tables with resolve_actors: false, and still labels everyone" do
      rows = nil
      queries = QueryCounter.capture do
        rows = render(described_class.new(scope_of(requests), actor: nil, resolve_actors: false))
      end

      expect(queries.grep(CollectionProbes::HOST_TABLES)).to be_empty
      expect(rows.map { |row| row[1] }).to include("User 0", "Admin 1 (admin)", "Manager 2")
    end

    it "builds presenters indistinguishable from ones built one at a time" do
      collected = render(described_class.new(scope_of(requests), actor: nil))
      individual = render(scope_of(requests).map { |request| ChangeRequests::RequestPresenter.new(request, actor: nil) })

      expect(collected).to eq(individual)
    end
  end

  describe "the collection" do
    let!(:requests) { page_of(3) }

    it "keeps the scope's order" do
      collection = described_class.new(scope_of(requests).reorder(created_at: :desc), actor: nil)

      expect(collection.map { |presenter| presenter.request.id }).to eq(requests.reverse.map(&:id))
    end

    it "accepts an array of requests as well as a relation" do
      expect(described_class.new(scope_of(requests).to_a, actor: nil).size).to eq(3)
    end

    it "passes actor, routes and resolve_actors to every presenter" do
      routes = Object.new
      collection = described_class.new(scope_of(requests), actor: approver, routes: routes, resolve_actors: false)

      expect(collection.map { |p| [p.actor, p.routes, p.resolve_actors?] }.uniq).to eq([[approver, routes, false]])
    end

    it "is empty for an empty page, and queries only for the rows" do
      expect { expect(described_class.new(ChangeRequests::Request.none, actor: nil).to_a).to eq([]) }
        .to issue_no_queries
    end

    it "loads and resolves once, however often it is iterated" do
      collection = described_class.new(scope_of(requests), actor: nil)
      render(collection)

      expect { render(collection) }.to issue_no_queries
    end
  end
end
