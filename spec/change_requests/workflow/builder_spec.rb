# frozen_string_literal: true

RSpec.describe ChangeRequests::Workflow::Builder do
  subject(:operation) { ChangeRequests::Operation.new("budget.approve") }

  let(:cfo) { Struct.new(:id, :name).new(1, "Cleo") }
  let(:general_counsel) { Struct.new(:id, :name).new(2, "Gene") }

  def permission(permission = nil, actor_type = nil)
    ChangeRequests::Workflow::Permission.new(permission: permission, actor_type: actor_type)
  end

  def declared_stage(&)
    operation.workflow(&)

    expect(operation.workflow.stages.size).to eq(1)

    operation.workflow.stages.first
  end

  def declared_quorum(**)
    stage = declared_stage { |w| w.stage(:approval, **) }

    expect(stage.quorums.size).to eq(1)

    stage.quorums.first
  end

  describe "reading the description back" do
    it "returns the description when called without a block, so Create still has a reader" do
      expect(operation.workflow).to be_empty
    end

    it "replaces the previous description rather than appending to it" do
      operation.workflow { |w| w.stage :approval, permissions: %w(owner), threshold: 2 }
      operation.workflow { |w| w.stage :review, permissions: %w(admin), threshold: 1 }

      expect(operation.workflow.stages.map(&:name)).to eq(%w(review))
    end

    it "leaves the previous description in place when the new one refuses" do
      operation.workflow { |w| w.stage :approval, permissions: %w(owner), threshold: 2 }

      expect { operation.workflow { |w| w.stage :approval, threshold: 3 } }
        .to raise_error(ChangeRequests::ConfigurationError)
      expect(operation.workflow.stages.first.quorums.first.threshold).to eq(2)
    end
  end

  describe "stages" do
    subject(:stages) do
      operation.workflow do |w|
        w.stage :triage,   permissions: %w(support), threshold: 1
        w.stage :approval, permissions: %w(finance), threshold: 2
        w.stage :sign_off, permissions: [{ actor_type: "Director" }], threshold: 1
      end

      operation.workflow.stages
    end

    it "numbers them from declaration order, which is the order they run in (§5.2)" do
      expect(stages.map(&:position)).to eq([1, 2, 3])
    end

    it "keeps the declared names as strings, matching the NOT NULL column (§5.2)" do
      expect(stages.map(&:name)).to eq(%w(triage approval sign_off))
    end

    it "defaults satisfied_by to the column's own default (§5.2)" do
      expect(stages.map(&:satisfied_by)).to eq(%i(any_quorum any_quorum any_quorum))
    end

    it "carries a declared satisfied_by" do
      stage = declared_stage do |w|
        w.stage(:operational, satisfied_by: :all_quorums) { |q| q.quorum :admin, actor_type: "Admin" }
      end

      expect(stage.satisfied_by).to eq(:all_quorums)
    end

    it "symbolises a satisfied_by declared as a string" do
      stage = declared_stage do |w|
        w.stage(:operational, satisfied_by: "all_quorums") { |q| q.quorum :admin, actor_type: "Admin" }
      end

      expect(stage.satisfied_by).to eq(:all_quorums)
    end
  end

  describe "the single-quorum stage (§6.4)" do
    it "describes one nameless quorum - 'which quorum' is not a meaningful question (§5.9)" do
      quorum = declared_quorum(permissions: %w(member_admin), threshold: 2)

      expect(quorum).to have_attributes(name: nil, position: 1, threshold: 2)
    end

    it "(a) permissions: two holders of a permission" do
      quorum = declared_quorum(permissions: %w(member_admin), threshold: 2)

      expect(quorum.permissions).to eq([permission("member_admin")])
      expect(quorum.eligible_actors).to be_empty
    end

    it "(b) actor_type: one actor of a class" do
      quorum = declared_quorum(actor_type: "Admin", threshold: 1)

      expect(quorum.permissions).to eq([permission(nil, "Admin")])
    end

    it "(c) match: one person holding both permissions" do
      quorum = declared_quorum(permissions: %w(finance compliance), match: :all, threshold: 1)

      expect(quorum.permissions).to eq([permission("finance"), permission("compliance")])
      expect(quorum.permission_match).to eq(:all)
    end

    it "(d) eligible_actors: only these two people" do
      quorum = declared_quorum(eligible_actors: [cfo, general_counsel], threshold: 2)

      expect(quorum.permissions).to be_empty
      expect(quorum.eligible_actors).to eq([cfo, general_counsel])
    end

    # Resolving (type, id) here would call actor_attributes before the host's config file has
    # necessarily run; Commands::Create resolves them instead.
    it "keeps the actor objects as declared, resolving nothing" do
      expect(declared_quorum(eligible_actors: [cfo]).eligible_actors.first).to equal(cfo)
    end

    it "defaults the threshold to one approval" do
      expect(declared_quorum(permissions: %w(owner)).threshold).to eq(1)
    end

    it "resolves an undeclared match lazily from the host's default (§5.3)" do
      quorum = declared_quorum(permissions: %w(finance compliance))
      ChangeRequests.config.default_permission_match = :all

      expect(quorum.permission_match).to eq(:all)
    end
  end

  describe "a block of quorums (§6.9)" do
    subject(:quorums) do
      declared_stage do |w|
        w.stage :operational, satisfied_by: :all_quorums do |q|
          q.quorum :admin,  permissions: [{ actor_type: "Admin" }], threshold: 1
          q.quorum :owners, permissions: %w(owner), threshold: 2
        end
      end.quorums
    end

    it "numbers them from declaration order (§5.3)" do
      expect(quorums.map(&:position)).to eq([1, 2])
    end

    it "keeps each declared name, which is what stage_satisfied metadata reports (§5.9)" do
      expect(quorums.map(&:name)).to eq(%w(admin owners))
    end

    it "carries each quorum's own threshold, which is the whole point of the level (§5.3)" do
      expect(quorums.map(&:threshold)).to eq([1, 2])
    end

    it "reads :permission and :actor_type off the hash form of permissions (§5.3)" do
      expect(quorums.map(&:permissions)).to eq([[permission(nil, "Admin")], [permission("owner")]])
    end

    it "keeps actor_type: as a top-level keyword, so 'any Admin' stays one line" do
      stage = declared_stage { |w| w.stage(:operational) { |q| q.quorum :admin, actor_type: "Admin" } }

      expect(stage.quorums.first.permissions).to eq([permission(nil, "Admin")])
    end

    it "applies a top-level actor_type: to every permission given alongside it" do
      stage = declared_stage do |w|
        w.stage(:operational) { |q| q.quorum :editors, permissions: %w(editor owner), actor_type: "User" }
      end

      expect(stage.quorums.first.permissions)
        .to eq([permission("editor", "User"), permission("owner", "User")])
    end

    it "accepts a quorum declared without a name, which is the shorthand written out" do
      stage = declared_stage do |w|
        w.stage(:approval) { |q| q.quorum permissions: %w(member_admin), threshold: 2 }
      end

      expect(stage.quorums.first.name).to be_nil
    end

    # The acceptance criterion of M2-1: one policy, one description, however it was spelled.
    it "produces the same description as the shorthand for the same policy" do
      operation.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
      shorthand = operation.workflow.stages

      operation.workflow do |w|
        w.stage(:approval) { |q| q.quorum permissions: %w(member_admin), threshold: 2 }
      end

      expect(operation.workflow.stages).to eq(shorthand)
    end
  end

  describe "declaration-time refusals" do
    it "refuses a quorum nobody can qualify for" do
      expect { operation.workflow { |w| w.stage :approval, threshold: 2 } }
        .to raise_error(ChangeRequests::ConfigurationError, /permissions|actor_type|eligible_actors/)
    end

    it "refuses a threshold below one, which no approval could ever reach" do
      expect { operation.workflow { |w| w.stage :approval, permissions: %w(owner), threshold: 0 } }
        .to raise_error(ChangeRequests::ConfigurationError, /threshold/)
    end

    it "refuses a non-integer threshold" do
      expect { operation.workflow { |w| w.stage :approval, permissions: %w(owner), threshold: 1.5 } }
        .to raise_error(ChangeRequests::ConfigurationError, /threshold/)
    end

    it "refuses a match the quorum column would reject" do
      expect { operation.workflow { |w| w.stage :approval, permissions: %w(owner), match: :either } }
        .to raise_error(ChangeRequests::ConfigurationError, /match/)
    end

    it "refuses a satisfied_by the stage column would reject (§5.2)" do
      expect { operation.workflow { |w| w.stage :approval, satisfied_by: :either, permissions: %w(owner) } }
        .to raise_error(ChangeRequests::ConfigurationError, /satisfied_by/)
    end

    it "refuses a stage with no name, because the column is NOT NULL (§5.2)" do
      expect { operation.workflow { |w| w.stage nil, permissions: %w(owner) } }
        .to raise_error(ChangeRequests::ConfigurationError, /name/)
    end

    it "refuses a duplicate stage name, which the unique index would refuse at creation (§5.2)" do
      declaration = lambda do |w|
        w.stage :approval, permissions: %w(owner)
        w.stage :approval, permissions: %w(admin)
      end

      expect { operation.workflow(&declaration) }
        .to raise_error(ChangeRequests::ConfigurationError, /approval.*twice/)
    end

    it "refuses a duplicate quorum name within its stage (§5.3)" do
      declaration = lambda do |w|
        w.stage :operational do |q|
          q.quorum :owners, permissions: %w(owner)
          q.quorum :owners, permissions: %w(admin)
        end
      end

      expect { operation.workflow(&declaration) }
        .to raise_error(ChangeRequests::ConfigurationError, /owners.*twice/)
    end

    it "accepts the same quorum name under two different stages" do
      operation.workflow do |w|
        w.stage(:operational) { |q| q.quorum :leads, permissions: %w(owner) }
        w.stage(:sign_off)    { |q| q.quorum :leads, permissions: %w(director) }
      end

      expect(operation.workflow.stages.map { |stage| stage.quorums.map(&:name) })
        .to eq([%w(leads), %w(leads)])
    end

    it "refuses a second quorum where either is unnamed, since neither could be reported (§5.9)" do
      declaration = lambda do |w|
        w.stage :operational do |q|
          q.quorum permissions: %w(owner)
          q.quorum :admin, permissions: %w(admin)
        end
      end

      expect { operation.workflow(&declaration) }
        .to raise_error(ChangeRequests::ConfigurationError, /name/)
    end

    it "refuses a stage block that declares no quorum" do
      expect { operation.workflow { |w| w.stage(:operational) { |_q| nil } } }
        .to raise_error(ChangeRequests::ConfigurationError, /no quorum/)
    end

    it "refuses a stage that takes both a block and an inline quorum, which says two things at once" do
      declaration = lambda do |w|
        w.stage(:operational, permissions: %w(owner)) { |q| q.quorum :admin, permissions: %w(admin) }
      end

      expect { operation.workflow(&declaration) }
        .to raise_error(ChangeRequests::ConfigurationError, /block/)
    end

    it "refuses a workflow that declares no stage at all" do
      expect { operation.workflow { |_w| nil } }
        .to raise_error(ChangeRequests::ConfigurationError, /no stage/)
    end
  end
end
