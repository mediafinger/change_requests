# frozen_string_literal: true

require "rails_helper"

module TimelineProbes
  class Target
    def self.call(**); end
  end
end

# M5-5: one entry per event row, in order, actor-labelled and translated (§11, §5.5).
RSpec.describe ChangeRequests::RequestPresenter, "#timeline" do
  subject(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  let(:requester) { User.create!(name: "Rita", email: "rita@example.com") }
  let(:approver) { Admin.create!(name: "Ada", roles: %w(member_admin)) }

  def declare(version: "2026-09-17", threshold: 1, override: false, &workflow)
    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = version
      op.service = "TimelineProbes::Target"
      op.override(permissions: %w(security_officer)) if override
      op.workflow(&workflow || ->(w) { w.stage :approval, permissions: %w(member_admin), threshold: threshold })
    end
  end

  def timeline(**)
    described_class.new(change_request.reload, actor: nil, **).timeline
  end

  def entry(kind)
    timeline.find { |row| row.kind == kind }
  end

  before { declare }

  describe "the entries" do
    it "is one per event, in the order they happened" do
      ChangeRequests::Commands::Comment.call(request: change_request, actor: requester, body: "Please hurry")
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)
      ChangeRequests::Commands::Execute.call(request: change_request, actor: approver)

      expect(timeline.map(&:kind)).to eq(
        %i(requested commented approved quorum_satisfied stage_satisfied execution_started executed)
      )
    end

    it "is a whole structure, comparable in one expectation" do
      event = change_request.events.sole

      expect(timeline).to eq(
        [ChangeRequests::Value::TimelineEntry.new(kind: :requested, actor: event.actor,
                                                  occurred_at: event.occurred_at, operation_version: "2026-09-17")]
      )
    end

    it "carries the body the actor wrote" do
      ChangeRequests::Commands::Comment.call(request: change_request, actor: requester, body: "Please hurry")

      expect(entry(:commented)).to have_attributes(body: "Please hurry", label: "Commented")
    end

    it "exposes metadata as the event stored it" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)

      expect(entry(:approved).metadata).to eq(change_request.events.find_by!(kind: "approved").metadata)
    end

    it "labels the actor" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)

      expect(entry(:approved).actor).to have_attributes(type: "Admin", label: "Ada (admin)")
    end
  end

  describe "labels" do
    # Not a humanize fallback, not "translation missing": the gem ships a label for every kind.
    it "ships a translation for every kind the trail can hold" do
      missing = ChangeRequests::Event::KINDS.reject { |kind| I18n.exists?("change_requests.timeline.#{kind}", :en) }

      expect(missing).to be_empty
    end

    it "reads it for the entry" do
      expect(entry(:requested).label).to eq(I18n.t("change_requests.timeline.requested"))
    end

    it "translates a host's own wording" do
      with_translations("change_requests.timeline.requested" => "Raised")

      expect(entry(:requested).label).to eq("Raised")
    end
  end

  # §5.5: the System sentinel is an ordinary ref, so a view renders it like anyone else.
  describe "a System entry" do
    before do
      declare(threshold: 2)
      change_request.update_columns(expires_at: 1.minute.ago)
      ChangeRequests::Commands::Expire.call(request: change_request.reload)
    end

    it "carries the System actor, neither deleted nor linked" do
      expect(entry(:expired).actor).to have_attributes(system?: true, label: "System", deleted?: false)
      expect(entry(:expired).actor.path(Object.new)).to be_nil
    end
  end

  # §5.5: each event is stamped from the live declaration, so a change mid-request shows.
  it "shows both versions of a declaration that changed mid-request" do
    declare(threshold: 2)
    change_request
    declare(version: "2026-10-01", threshold: 2)
    ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)

    expect(timeline.map { |row| [row.kind, row.operation_version] })
      .to eq([[:requested, "2026-09-17"], [:approved, "2026-10-01"]])
  end

  describe "details from metadata" do
    it "names the quorum a quorum_satisfied entry met" do
      declare do |w|
        w.stage :operational, satisfied_by: :any_quorum do |q|
          q.quorum :owners, permissions: %w(member_admin), threshold: 1
          q.quorum :admins, permissions: %w(nobody), threshold: 1
        end
      end
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)

      expect(entry(:quorum_satisfied).detail).to eq("Owners")
    end

    it "names the stage for a nameless quorum" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)

      expect([entry(:quorum_satisfied).detail, entry(:stage_satisfied).detail]).to eq(%w(Approval Approval))
    end

    it "names the shortfall an override bypassed" do
      declare(threshold: 2, override: true)
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)
      officer = Manager.create!(id: "mgr-1", name: "Olive", roles: %w(security_officer))
      ChangeRequests::Commands::Override.call(request: change_request, actor: officer)

      expect(entry(:overridden).detail).to eq("1 of 2 approvals")
    end

    it "names the attempt a reaped entry wrote off and how long it was stuck" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)
      change_request.update!(status: "executing")
      change_request.attempts.create!(number: 1, started_at: 2.hours.ago, executer: approver)
      ChangeRequests::Commands::Reap.call(request: change_request)

      expect(entry(:reaped).detail).to eq("Attempt 1, stuck for 2 hours")
    end

    it "names the attempt an execution entry belongs to" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)
      ChangeRequests::Commands::Execute.call(request: change_request, actor: approver)

      expect([entry(:execution_started).detail, entry(:executed).detail]).to eq(["Attempt 1", "Attempt 1"])
    end

    it "has none for an entry with nothing to add" do
      expect(entry(:requested).detail).to be_nil
    end

    it "translates the detail wording" do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)
      ChangeRequests::Commands::Execute.call(request: change_request, actor: approver)
      with_translations("change_requests.timeline_details.attempt" => "Run %{attempt}")

      expect(entry(:executed).detail).to eq("Run 1")
    end
  end

  describe "queries" do
    before do
      ChangeRequests::Commands::Approve.call(request: change_request, actor: approver)
      ChangeRequests::Commands::Comment.call(request: change_request, actor: requester, body: "Thanks")
      change_request.reload
    end

    # User and Admin, once each however many entries name them. System is nobody's class.
    it "resolves every actor on the timeline in one query per actor type, then none" do
      presenter = described_class.new(change_request, actor: nil)
      queries = QueryCounter.capture { presenter.timeline }

      expect(queries.grep(/\b(users|admins)\b/).size).to eq(2)
      expect { presenter.timeline.map { |row| row.actor.record } }.to issue_no_queries
    end

    it "touches no host table with resolve_actors: false" do
      queries = QueryCounter.capture do
        described_class.new(change_request, actor: nil, resolve_actors: false).timeline.map { |row| row.actor.label }
      end

      expect(queries.grep(/\b(users|admins)\b/)).to be_empty
    end

    it "reads a preloaded request without querying the gem's tables" do
      preloaded = ChangeRequests::Request.includes(:events).find(change_request.id)

      expect { described_class.new(preloaded, actor: nil, resolve_actors: false).timeline }.to issue_no_queries
    end
  end
end
