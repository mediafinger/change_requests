# frozen_string_literal: true

require "rails_helper"

# §6.9's four shapes, declared exactly as the section prints them, through Commands::Create and
# down to the rows. M2-6 approves through them; this proves the declaration reaches the database
# as the section describes it.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "the §6.9 workflow shapes" do
  subject(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "order.pay", requester: requester, payload: {})
  end

  let(:requester) { Admin.create!(name: "Ada") }

  # §6.9 (d) gates its last stage on a Director. The dummy application registers no such class, and
  # an unregistered actor_type on a permission row is refused at creation (§5.7) - so register it.
  before { ChangeRequests.config.actor_type("Director") { |type| type.label = ->(record) { record.name } } }

  def declare(&)
    ChangeRequests.operations.define("order.pay") do |op|
      op.version = "2026-09-12"
      op.service = "Orders::Pay"
      op.workflow(&)
    end
  end

  def graph(request)
    request.stages.order(:position).map do |stage|
      [stage.name, stage.satisfied_by, stage.quorums.order(:position).map(&:name)]
    end
  end

  def rows_of(quorum)
    quorum.permissions.map { |row| [row.permission, row.actor_type] }
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

    it "writes one stage holding two alternative quorums" do
      expect(graph(change_request)).to eq([["operational", "any_quorum", %w(admin owners)]])
    end

    it "gives each quorum its own threshold and eligibility" do
      admin, owners = change_request.stages.sole.quorums.order(:position).to_a

      expect(admin).to have_attributes(threshold: 1, permission_match: "any")
      expect(rows_of(admin)).to eq([[nil, "Admin"]])
      expect(owners).to have_attributes(threshold: 2, permission_match: "any")
      expect(rows_of(owners)).to eq([["owner", nil]])
    end
  end

  describe "(b) one Admin AND two Owners, then a Director" do
    before do
      declare do |w|
        w.stage :operational, satisfied_by: :all_quorums do |q|
          q.quorum :admin,  permissions: [{ actor_type: "Admin" }], threshold: 1
          q.quorum :owners, permissions: %w(owner), threshold: 2
        end

        w.stage :director, permissions: %w(director), threshold: 1
      end
    end

    # One word - :any_quorum to :all_quorums - is the entire difference between (a) and (b).
    it "writes two sequential stages, the first AND-ing its quorums" do
      expect(graph(change_request))
        .to eq([["operational", "all_quorums", %w(admin owners)], ["director", "any_quorum", [nil]]])
    end

    it "leaves the second stage's only quorum nameless (§5.9)" do
      director = change_request.stages.find_by!(position: 2).quorums.sole

      expect(director).to have_attributes(name: nil, threshold: 1)
      expect(rows_of(director)).to eq([["director", nil]])
    end

    it "starts the request on stage one" do
      expect(change_request.current_stage_position).to eq(1)
      expect(change_request.current_stage.name).to eq("operational")
    end
  end

  describe "(c) the GitHub shortcut - two peers, or one admin" do
    before do
      declare do |w|
        w.stage :review, satisfied_by: :any_quorum do |q|
          q.quorum :peers, permissions: %w(member), threshold: 2
          q.quorum :admin, permissions: %w(admin), threshold: 1
        end
      end
    end

    it "writes the two routes in declaration order" do
      expect(graph(change_request)).to eq([["review", "any_quorum", %w(peers admin)]])
      expect(change_request.stages.sole.quorums.order(:position).map(&:threshold)).to eq([2, 1])
    end
  end

  describe "(d) everything at once" do
    let(:cfo) { Admin.create!(name: "Cleo") }
    let(:general_counsel) { User.create!(name: "Gene", email: "gene@example.com") }

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

    it "writes four stages in declaration order, the middle one AND-ing three quorums" do
      expect(graph(change_request)).to eq(
        [
          ["triage",   "any_quorum",  [nil]],
          ["approval", "all_quorums", %w(risk money named)],
          ["sign_off", "any_quorum",  [nil]],
        ]
      )
    end

    it "carries the per-quorum match, so :risk needs both permissions of one actor (§5.3)" do
      quorums = change_request.stages.find_by!(name: "approval").quorums

      expect(quorums.find_by!(name: "risk")).to have_attributes(permission_match: "all", threshold: 1)
      expect(quorums.find_by!(name: "money")).to have_attributes(permission_match: "any", threshold: 2)
    end

    it "resolves the named approvers to (type, id) at creation, not at declaration (§9.1)" do
      named = change_request.stages.find_by!(name: "approval").quorums.find_by!(name: "named")

      expect(named.permissions).to be_empty
      expect(named.eligible_actors.map { |row| [row.actor_type, row.actor_id] })
        .to contain_exactly(["Admin", cfo.id.to_s], ["User", general_counsel.id.to_s])
    end

    it "gates the last stage on an actor class rather than a permission" do
      sign_off = change_request.stages.find_by!(name: "sign_off").quorums.sole

      expect(rows_of(sign_off)).to eq([[nil, "Director"]])
    end
  end
end
