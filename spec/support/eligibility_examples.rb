# frozen_string_literal: true

# §5.3's eligibility predicate, as a table.
#
# The including group defines `eligible?(actor:, quorum:)`. M1b-2's subject is
# `Authorization::Permissions#allows?`; M9c adds a second group whose `eligible?` runs the SQL of
# `Request.awaiting_approval_from`, and the two are then asserted equal over every cell here. That
# is the point of keeping the table out of the spec file.
RSpec.shared_examples "the eligibility predicate" do
  let(:change_request) { build_request }
  let(:stage) { build_stage(change_request) }

  # roles, and therefore permissions, differ per actor class - Admin's lambda appends "admin".
  let(:editor_user) { User.create!(name: "Edith", email: "edith@example.com", roles: %w(editor)) }
  let(:plain_user) { User.create!(name: "Paul", email: "paul@example.com") }
  let(:editor_admin) { Admin.create!(name: "Ada", roles: %w(editor)) }
  let(:plain_admin) { Admin.create!(name: "Alan") }
  let(:editor_manager) { Manager.create!(id: "m-1", name: "Mel", roles: %w(editor)) }

  def quorum_with(rows, match: :any, named: [])
    quorum = build_quorum(stage, permission_match: match.to_s)

    rows.each { |row| quorum.permissions.create!(**row) }
    named.each { |actor| quorum.eligible_actors.create!(actor:) }

    quorum
  end

  # §5.3's 2x2: permission and actor_type are independently nullable. One row per cell, under each
  # match mode, against each of the dummy application's three actor classes.
  {
    'a ("User", "editor") row - Users holding :editor' => {
      rows: [{ permission: "editor", actor_type: "User" }],
      eligible: %i(editor_user),
      refused: %i(plain_user editor_admin editor_manager),
    },
    'a (NULL, "editor") row - anyone holding :editor' => {
      rows: [{ permission: "editor", actor_type: nil }],
      eligible: %i(editor_user editor_admin editor_manager),
      refused: %i(plain_user plain_admin),
    },
    'a ("User", NULL) row - any User, whatever their roles' => {
      rows: [{ permission: nil, actor_type: "User" }],
      eligible: %i(editor_user plain_user),
      refused: %i(editor_admin editor_manager),
    },
  }.each do |description, cells|
    context "with #{description}" do
      %i(any all).each do |match|
        # A single row counts the same either way: "any of one" and "all of one" are one row.
        context "under permission_match #{match}" do
          cells[:eligible].each do |actor_name|
            it "admits #{actor_name}" do
              expect(eligible?(actor: public_send(actor_name), quorum: quorum_with(cells[:rows], match:)))
                .to be(true)
            end
          end

          cells[:refused].each do |actor_name|
            it "refuses #{actor_name}" do
              expect(eligible?(actor: public_send(actor_name), quorum: quorum_with(cells[:rows], match:)))
                .to be(false)
            end
          end
        end
      end
    end
  end

  # The fourth cell, rejected. Two gates already stop it reaching the database, so the predicate is
  # asked in memory - "constrains nothing" must never read as "matches everyone" at any layer.
  describe "the (NULL, NULL) cell" do
    let(:quorum) { build_quorum(stage) }

    it "is refused by the model" do
      expect(quorum.permissions.new(permission: nil, actor_type: nil)).not_to be_valid
    end

    it "is refused by the CHECK constraint even when the validation is skipped" do
      row = quorum.permissions.new(permission: nil, actor_type: nil)

      expect { row.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    %i(any all).each do |match|
      it "matches nobody under permission_match #{match}, were it ever to exist" do
        quorum = build_quorum(stage, permission_match: match.to_s)
        quorum.permissions.load
        quorum.permissions.new(permission: nil, actor_type: nil)

        expect(eligible?(actor: editor_admin, quorum:)).to be(false)
      end
    end
  end

  describe "several permission rows" do
    let(:rows) { [{ permission: "finance" }, { permission: "compliance" }] }
    let(:both) { Admin.create!(name: "Fiona", roles: %w(finance compliance)) }
    let(:one) { Admin.create!(name: "Cara", roles: %w(compliance)) }

    context "under permission_match any - at least one row matches" do
      it "admits an actor holding either" do
        expect(eligible?(actor: one, quorum: quorum_with(rows, match: :any))).to be(true)
      end

      it "refuses an actor holding neither" do
        expect(eligible?(actor: plain_admin, quorum: quorum_with(rows, match: :any))).to be(false)
      end
    end

    # A per-actor AND: *this* actor holds every listed permission. Identical rows, opposite meaning,
    # which is why the mode is a column beside them and not global config (§5.3).
    context "under permission_match all - this actor satisfies every row" do
      it "admits an actor holding both" do
        expect(eligible?(actor: both, quorum: quorum_with(rows, match: :all))).to be(true)
      end

      it "refuses an actor holding only one" do
        expect(eligible?(actor: one, quorum: quorum_with(rows, match: :all))).to be(false)
      end
    end
  end

  describe "named approvers" do
    it "admits the named actor whatever their permissions (§5.3)" do
      quorum = quorum_with([], named: [plain_admin])

      expect(eligible?(actor: plain_admin, quorum:)).to be(true)
    end

    it "refuses anybody else" do
      quorum = quorum_with([], named: [plain_admin])

      expect(eligible?(actor: editor_admin, quorum:)).to be(false)
    end

    it "separates the same id held by two different classes" do
      quorum = build_quorum(stage)
      quorum.eligible_actors.create!(actor_type: "User", actor_id: plain_admin.id.to_s)

      expect(eligible?(actor: plain_admin, quorum: quorum.reload)).to be(false)
    end

    it "is OR-ed with the permission rows, not AND-ed" do
      quorum = quorum_with([{ permission: "editor" }], named: [plain_admin])

      expect(eligible?(actor: plain_admin, quorum:)).to be(true)
      expect(eligible?(actor: editor_user, quorum:)).to be(true)
    end
  end

  # "all of nothing" is vacuously true, which would make a named-approver quorum admit everyone.
  describe "a quorum with no permission rows" do
    %i(any all).each do |match|
      it "admits nobody by permission under #{match}" do
        expect(eligible?(actor: editor_admin, quorum: quorum_with([], match:))).to be(false)
      end
    end
  end

  describe "an actor class that may not approve (§9.1)" do
    before { ChangeRequests.config.actor_types.fetch("Admin").may_approve = false }

    it "satisfies no quorum, whatever its permissions say" do
      expect(eligible?(actor: editor_admin, quorum: quorum_with([{ permission: "editor" }]))).to be(false)
    end

    it "does not satisfy one that names it either" do
      expect(eligible?(actor: editor_admin, quorum: quorum_with([], named: [editor_admin]))).to be(false)
    end
  end

  it "refuses an actor whose class is not registered, which is the allowlist working (§9.1)" do
    expect { eligible?(actor: Object.new, quorum: quorum_with([{ permission: "editor" }])) }
      .to raise_error(ChangeRequests::UnknownActorType)
  end
end
