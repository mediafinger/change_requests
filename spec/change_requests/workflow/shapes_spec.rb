# frozen_string_literal: true

require "rails_helper"

# §6.9's four shapes, declared exactly as the section prints them: through Commands::Create down to
# the rows, and then approved through with the actors the section names. These are the examples in
# the docs, and §15.2 asks for them end to end so they cannot rot.
#
# Execution is M3a, so every sequence ends at `approved` - which is the last state M2 can reach.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "the §6.9 workflow shapes" do
  subject(:change_request) do
    ChangeRequests::Commands::Create.call(operation_key: "order.pay", requester: requester, payload: {})
  end

  # §6.9's alice. Holding nothing, so no quorum of any shape counts her - and the separation of
  # duties would refuse her anyway (§7.2).
  let(:requester) { user("Alice") }

  def user(name, *roles)
    User.create!(name: name, email: "#{name.downcase}@example.com", roles: roles)
  end

  def approve(actor)
    ChangeRequests::Commands::Approve.call(request: change_request, actor: actor)
  end

  # The refusal reason, because §6.9 prints one: `# => NotApprovable (reason: :stage_not_current)`.
  def refusal_for(actor)
    approve(actor)

    nil
  rescue ChangeRequests::NotApprovable => e
    e.reason
  end

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

    describe "approving through it" do
      it "closes on one Admin, that quorum needing only one" do
        approve(Admin.create!(name: "Amy"))

        expect(change_request.reload.status).to eq("approved")
      end

      it "closes on two Owners instead - the other route to the same gate" do
        approve(user("Olga", "owner"))

        expect(change_request.reload.status).to eq("pending")

        approve(user("Omar", "owner"))

        expect(change_request.reload.status).to eq("approved")
      end

      it "refuses an actor who qualifies for neither quorum" do
        expect(refusal_for(user("Nemo"))).to eq(:not_permitted)
      end
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

    describe "approving through it" do
      let(:director_alan) { user("Alan", "director") }

      it "refuses the stage-two Director while stage one is current (§6.9)" do
        expect(refusal_for(director_alan)).to eq(:stage_not_current)
      end

      # §6.9: "this really is three people". Both quorums must be met, so the Admin closing :admin
      # leaves :owners still needing its two.
      it "takes an Admin and two distinct Owners, then the Director" do
        approve(Admin.create!(name: "Amy"))
        approve(user("Olga", "owner"))

        expect(change_request.reload.current_stage_position).to eq(1)

        approve(user("Omar", "owner"))

        expect(change_request.reload)
          .to have_attributes(status: "pending", current_stage_position: 2)

        approve(director_alan)

        expect(change_request.reload.status).to eq("approved")
      end

      # The known gap, pending rather than absent (Q1, Q10): it reads as "not written yet", and
      # RSpec reddens it the moment M9a makes it pass.
      it "refuses to close stage one on two people where the shape demands three" do
        pending "M9a: countable_quorums links an approval to every quorum the actor qualifies for, " \
                "so an Admin who also holds `owner` closes both quorums of an all_quorums stage " \
                "(§5.3, §7.1, deferred from M1b-5)"

        approve(Admin.create!(name: "Amy", roles: %w(owner)))
        approve(Admin.create!(name: "Abe", roles: %w(owner)))

        expect(change_request.reload.current_stage_position).to eq(1)
      end
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

    describe "approving through it" do
      it "closes on one admin - the shortcut" do
        approve(user("Alex", "admin"))

        expect(change_request.reload.status).to eq("approved")
      end

      it "closes on two peers - the ordinary route" do
        approve(user("Pia", "member"))

        expect(change_request.reload.status).to eq("pending")

        approve(user("Pat", "member"))

        expect(change_request.reload.status).to eq("approved")
      end
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

    it "writes three stages in declaration order, the middle one AND-ing three quorums" do
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

    # §6.9's own sequence, with the thresholds the declaration above actually carries: :money and
    # :named each want two, where the section's comments abbreviate to one apiece.
    describe "approving through it (§6.9's worked sequence)" do
      let(:director_alan) { Director.create!(name: "Alan") }
      let(:support_sam) { user("Sam", "support") }
      let(:risk_rita) { user("Rita", "risk", "compliance") }

      it "refuses a stage-three Director on a stage-one request" do
        expect(refusal_for(director_alan)).to eq(:stage_not_current)
      end

      it "walks the three stages in order, satisfying every quorum of the middle one" do
        approve(support_sam)

        expect(change_request.reload.current_stage_position).to eq(2)

        approve(risk_rita)
        approve(user("Fay", "finance"))
        approve(user("Frank", "finance"))
        approve(cfo)

        expect(change_request.reload.current_stage_position).to eq(2)

        approve(general_counsel)

        expect(change_request.reload)
          .to have_attributes(status: "pending", current_stage_position: 3)

        approve(director_alan)

        expect(change_request.reload.status).to eq("approved")
      end

      it "counts each approver into the one quorum they qualify for" do
        approve(support_sam)
        approve(risk_rita)
        approve(cfo)

        quorums = change_request.stages.find_by!(name: "approval").quorums

        expect(quorums.pluck(:name, :status).sort)
          .to eq([%w(money pending), %w(named pending), %w(risk satisfied)])
      end
    end
  end
end
