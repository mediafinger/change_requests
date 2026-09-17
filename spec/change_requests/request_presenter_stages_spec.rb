# frozen_string_literal: true

require "rails_helper"

# M5-3: RequestPresenter#stages against §6.9's four shapes, at every step. `approved` counts the
# approval_quorums links M9a-1 writes, so a stage needing three people never shows as met with two.
RSpec.describe ChangeRequests::RequestPresenter, "#stages" do
  subject(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "order.pay", requester: user("Alice"), payload: {})
  end

  def user(name, *roles)
    User.create!(name: name, email: "#{name.downcase}@example.com", roles: roles)
  end

  def approve(actor)
    ChangeRequests::Commands::Approve.call(request: change_request, actor: actor)
  end

  def declare(&)
    ChangeRequests.operations.define("order.pay") do |op|
      op.version = "2026-09-17"
      op.service = "Orders::Pay"
      op.workflow(&)
    end
  end

  def stages(**)
    described_class.new(change_request.reload, actor: nil, **).stages
  end

  # One line per stage: what a progress view shows.
  def progress(**)
    stages(**).map do |stage|
      [stage.name, stage.status, stage.current?, stage.satisfied_via, stage.remaining_options,
       stage.quorums.map { |quorum| [quorum.label, quorum.approved, quorum.required, quorum.satisfied?, quorum.approvers] }]
    end
  end

  describe "(a) one Admin OR two Owners" do
    before do
      declare do |w|
        w.stage :operational, satisfied_by: :any_quorum do |q|
          q.quorum :admin,  permissions: [{ actor_type: "Admin" }], threshold: 1
          q.quorum :owners, permissions: %w(owner), threshold: 2
        end
      end
    end

    it "lists both routes before anyone has approved" do
      expect(progress).to eq(
        [["operational", :pending, true, nil, ["1 from Admin", "2 from Owners"],
          [["Admin", 0, 1, false, []], ["Owners", 0, 2, false, []]]]]
      )
    end

    # §11: the one place a naive "1/2" lies. Half of one route is not half of the stage.
    it "still lists both routes once one is half done" do
      approve(user("Olga", "owner"))

      expect(progress).to eq(
        [["operational", :pending, true, nil, ["1 from Admin", "1 more from Owners"],
          [["Admin", 0, 1, false, []], ["Owners", 1, 2, false, ["Olga"]]]]]
      )
    end

    it "names the route that closed it, and lists nothing outstanding" do
      approve(user("Olga", "owner"))
      approve(Admin.create!(name: "Amy"))

      expect(progress).to eq(
        [["operational", :closed, false, "admin", [],
          [["Admin", 1, 1, true, ["Amy (admin)"]], ["Owners", 1, 2, false, ["Olga"]]]]]
      )
    end

    it "is one whole structure, comparable in one expectation" do
      approve(user("Olga", "owner"))

      expect(stages).to eq(
        [
          ChangeRequests::Value::StageProgress.new(
            name: "operational", position: 1, status: :pending, satisfied: false, current: true,
            satisfied_by: :any_quorum, remaining_options: ["1 from Admin", "1 more from Owners"],
            quorums: [
              ChangeRequests::Value::Quorum.new(name: "admin", required: 1, approved: 0, satisfied: false),
              ChangeRequests::Value::Quorum.new(name: "owners", required: 2, approved: 1, satisfied: false,
                                                approvers: ["Olga"]),
            ]
          ),
        ]
      )
    end
  end

  describe "(b) one Admin AND two Owners, then a Director" do
    let(:admin_owner) { Admin.create!(name: "Ada", roles: %w(owner)) }

    before do
      declare do |w|
        w.stage :operational, satisfied_by: :all_quorums do |q|
          q.quorum :admin,  permissions: [{ actor_type: "Admin" }], threshold: 1
          q.quorum :owners, permissions: %w(owner), threshold: 2
        end

        w.stage :director, permissions: %w(director), threshold: 1
      end
    end

    it "lists every quorum outstanding, and the later stage in full" do
      expect(progress).to eq(
        [
          ["operational", :pending, true, nil, ["1 from Admin", "2 from Owners"],
           [["Admin", 0, 1, false, []], ["Owners", 0, 2, false, []]]],
          ["director", :pending, false, nil, ["1 from Director"], [["Director", 0, 1, false, []]]],
        ]
      )
    end

    # She holds owner too, but one approval counts toward one quorum of an all_quorums stage.
    it "counts an Admin who is also an owner toward Admin only" do
      approve(admin_owner)

      expect(progress.first).to eq(
        ["operational", :pending, true, nil, ["2 from Owners"],
         [["Admin", 1, 1, true, ["Ada (admin)"]], ["Owners", 0, 2, false, []]]]
      )
    end

    it "is not met with two people, which is the point of M9a" do
      approve(admin_owner)
      approve(user("Olga", "owner"))

      expect(progress.first).to eq(
        ["operational", :pending, true, nil, ["1 more from Owners"],
         [["Admin", 1, 1, true, ["Ada (admin)"]], ["Owners", 1, 2, false, ["Olga"]]]]
      )
    end

    it "moves on with the third distinct person, naming no single route for an AND" do
      approve(admin_owner)
      approve(user("Olga", "owner"))
      approve(user("Otto", "owner"))

      expect(progress).to eq(
        [
          ["operational", :closed, false, nil, [],
           [["Admin", 1, 1, true, ["Ada (admin)"]], ["Owners", 2, 2, true, %w(Olga Otto)]]],
          ["director", :pending, true, nil, ["1 from Director"], [["Director", 0, 1, false, []]]],
        ]
      )
    end

    it "ends with nothing current and nothing outstanding" do
      approve(admin_owner)
      approve(user("Olga", "owner"))
      approve(user("Otto", "owner"))
      approve(user("Alan", "director"))

      expect(progress.map { |name, status, current, _, remaining, _| [name, status, current, remaining] })
        .to eq([["operational", :closed, false, []], ["director", :closed, false, []]])
    end
  end

  describe "(c) two peers, or one admin" do
    before do
      declare do |w|
        w.stage :review, satisfied_by: :any_quorum do |q|
          q.quorum :peers, permissions: %w(member), threshold: 2
          q.quorum :admin, permissions: %w(admin), threshold: 1
        end
      end
    end

    it "lists both routes at every step until one closes" do
      expect(progress.first[4]).to eq(["2 from Peers", "1 from Admin"])

      approve(user("Pat", "member"))
      expect(progress.first[4]).to eq(["1 more from Peers", "1 from Admin"])

      approve(user("Pia", "member"))
      expect(progress.first.first(5)).to eq(["review", :closed, false, "peers", []])
    end
  end

  describe "(d) everything at once" do
    let(:cfo) { Manager.create!(id: "cfo", name: "Cleo") }
    let(:general_counsel) { Manager.create!(id: "gc", name: "Gene") }

    before do
      named = [cfo, general_counsel]

      declare do |w|
        w.stage :triage, permissions: %w(support), threshold: 1

        w.stage :approval, satisfied_by: :all_quorums do |q|
          q.quorum :risk,  permissions: %w(risk compliance), match: :all, threshold: 1
          q.quorum :money, permissions: %w(finance),                      threshold: 2
          q.quorum :named, eligible_actors: named,                        threshold: 2
        end

        w.stage :sign_off, permissions: [{ actor_type: "Director" }], threshold: 1
      end
    end

    def approval_stage(**)
      progress(**).find { |stage| stage.first == "approval" }
    end

    it "walks all three stages, with the right one current at each step" do
      currents = -> { progress.map { |stage| stage[2] } }

      expect(currents.call).to eq([true, false, false])

      approve(user("Sam", "support"))
      expect(currents.call).to eq([false, true, false])

      approve(user("Rita", "risk", "compliance"))
      approve(user("Fay", "finance"))
      approve(user("Frank", "finance"))
      approve(cfo)
      approve(general_counsel)
      expect(currents.call).to eq([false, false, true])

      approve(Director.create!(name: "Alan"))
      expect(currents.call).to eq([false, false, false])
    end

    # M9a-3: "1 more from Cleo or Gene", never "1 more from Named".
    it "lists a named quorum's actors by label, dropping each as they approve" do
      approve(user("Sam", "support"))

      expect(approval_stage[4]).to eq(["1 from Risk", "2 from Money", "2 from Cleo or Gene"])

      approve(cfo)

      expect(approval_stage).to eq(
        ["approval", :pending, true, nil, ["1 from Risk", "2 from Money", "1 more from Gene"],
         [["Risk", 0, 1, false, []], ["Money", 0, 2, false, []], ["Named", 1, 2, false, ["Cleo"]]]]
      )
    end

    it "lists the named actors from the row alone, with no host query and after they are gone" do
      approve(user("Sam", "support"))
      change_request.reload
      cfo.destroy!

      presenter = described_class.new(change_request, actor: nil, resolve_actors: false)

      host_tables = /\b(users|admins|managers|directors|organizations)\b/
      queries = QueryCounter.capture { presenter.stages }

      expect(queries.grep(host_tables)).to be_empty
      expect(presenter.stages.find { |stage| stage.name == "approval" }.remaining_options.last)
        .to eq("2 from Cleo or Gene")
    end

    it "lists what is outstanding across the AND, and nothing once it is met" do
      approve(user("Sam", "support"))
      approve(user("Rita", "risk", "compliance"))
      approve(user("Fay", "finance"))

      expect(approval_stage[4]).to eq(["1 more from Money", "2 from Cleo or Gene"])

      approve(user("Frank", "finance"))
      approve(cfo)
      approve(general_counsel)

      expect(approval_stage.first(5)).to eq(["approval", :closed, false, nil, []])
    end
  end

  describe "a stopped request" do
    before do
      declare do |w|
        w.stage :operational, satisfied_by: :any_quorum do |q|
          q.quorum :admin,  permissions: [{ actor_type: "Admin" }], threshold: 1
          q.quorum :owners, permissions: %w(owner), threshold: 2
        end
      end
    end

    it "shows a rejected stage as not current, with nothing outstanding" do
      ChangeRequests::Commands::Reject.call(request: change_request, actor: Admin.create!(name: "Amy"), reason: "No")

      expect(progress.first.first(5)).to eq(["operational", :rejected, false, nil, []])
    end
  end

  describe "rendering" do
    before do
      declare do |w|
        w.stage :operational, satisfied_by: :any_quorum do |q|
          q.quorum :admin,  permissions: [{ actor_type: "Admin" }], threshold: 1
          q.quorum :owners, permissions: %w(owner), threshold: 2
        end
      end
    end

    it "translates the remaining-option wording" do
      approve(user("Olga", "owner"))
      with_translations("change_requests.progress.remaining" => "%{count} needed: %{who}",
                        "change_requests.progress.remaining_more" => "%{count} still needed: %{who}")

      expect(stages.first.remaining_options).to eq(["1 needed: Admin", "1 still needed: Owners"])
    end

    it "translates stage and quorum labels as §5.9 does" do
      with_translations("change_requests.stages.operational" => "Operational review",
                        "change_requests.quorums.owners" => "Account owners")

      expect([stages.first.label, stages.first.quorums.last.label, stages.first.remaining_options.last])
        .to eq(["Operational review", "Account owners", "2 from Account owners"])
    end

    it "takes approver labels from the approval rows, even for a deleted approver" do
      olga = user("Olga", "owner")
      approve(olga)
      olga.destroy!

      expect(stages(resolve_actors: false).first.quorums.last.approvers).to eq(["Olga"])
    end

    it "costs the same number of queries however many people approved" do
      approve(user("Olga", "owner"))
      change_request.reload
      few = QueryCounter.capture { described_class.new(change_request, actor: nil).stages }.size

      approve(user("Otto", "owner"))
      change_request.reload
      more = QueryCounter.capture { described_class.new(change_request, actor: nil).stages }.size

      expect(more).to eq(few)
    end

    it "reads a preloaded request without querying" do
      preloaded = ChangeRequests::Request.includes(
        :events, stages: { quorums: [:permissions, :eligible_actors, { approval_quorums: :approval }] }
      ).find(change_request.id)

      expect { described_class.new(preloaded, actor: nil).stages }.to issue_no_queries
    end
  end
end
