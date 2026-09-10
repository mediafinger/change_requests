# frozen_string_literal: true

RSpec.describe ChangeRequests::Operation do
  subject(:operation) { described_class.new("members.update_roles") }

  let(:cfo) { Struct.new(:id, :name).new(1, "Cleo") }
  let(:general_counsel) { Struct.new(:id, :name).new(2, "Gene") }

  def permission(permission = nil, actor_type = nil)
    ChangeRequests::Workflow::Permission.new(permission: permission, actor_type: actor_type)
  end

  def declared_quorum(**)
    operation.approvals(**)
    stage = operation.workflow.stages.first

    expect(operation.workflow.stages.size).to eq(1)
    expect(stage.quorums.size).to eq(1)

    stage.quorums.first
  end

  describe "attributes" do
    it "keeps the key as a string, whatever it was declared as" do
      expect(described_class.new(:"members.update_roles").key).to eq("members.update_roles")
    end

    it "defaults the dispatch target's method to the documented :call (§6.12)" do
      expect(operation.method_name).to eq(:call)
    end

    it "symbolises a method name declared as a string" do
      operation.method_name = "perform"

      expect(operation.method_name).to eq(:perform)
    end

    it "is not idempotent unless the declaration says so (§8)" do
      expect(operation.idempotent).to be(false)
    end

    it "starts with no workflow at all, so an operation must declare who approves it" do
      expect(operation.workflow.stages).to be_empty
    end
  end

  describe "defaults resolved from the configuration" do
    # Lazily, not at declaration time: initializer order is the host's, and an operations file that
    # loads before the config file should still see the host's defaults.
    it "takes max_attempts from config.default_max_attempts" do
      ChangeRequests.config.default_max_attempts = 5

      expect(operation.max_attempts).to eq(5)
    end

    it "prefers an explicitly declared max_attempts" do
      ChangeRequests.config.default_max_attempts = 5
      operation.max_attempts = 2

      expect(operation.max_attempts).to eq(2)
    end

    it "takes expires_in from config.default_expires_in" do
      ChangeRequests.config.default_expires_in = 604_800

      expect(operation.expires_in).to eq(604_800)
    end

    # nil is a value here, not an absence: it means "this one never expires".
    it "lets an operation opt out of a host-wide expiry by declaring nil" do
      ChangeRequests.config.default_expires_in = 604_800
      operation.expires_in = nil

      expect(operation.expires_in).to be_nil
    end
  end

  describe "#validate!" do
    it "passes once a version is declared" do
      operation.version = "2026-09-11"

      expect(operation.validate!).to be(true)
    end

    it "refuses an operation with no version (§5.10)" do
      expect { operation.validate! }
        .to raise_error(ChangeRequests::ConfigurationError, /members\.update_roles.*version/m)
    end

    it "refuses a blank version, which snapshots onto every request as a NOT NULL column" do
      operation.version = "  "

      expect { operation.validate! }.to raise_error(ChangeRequests::ConfigurationError, /version/)
    end
  end

  describe "#approvals" do
    it "describes one stage holding one quorum (§6.4)" do
      operation.approvals permissions: %w(member_admin), required: 2
      stage = operation.workflow.stages.first

      expect(operation.workflow.stages.size).to eq(1)
      expect(stage.position).to eq(1)
      expect(stage.satisfied_by).to eq(:any_quorum)
      expect(stage.quorums.size).to eq(1)
    end

    it "names the stage, because change_request_stages.name is NOT NULL (§5.2)" do
      operation.approvals permissions: %w(member_admin), required: 2

      expect(operation.workflow.stages.first.name).to eq("approval")
    end

    it "leaves the quorum nameless - 'which quorum' is not a meaningful question here (§5.9)" do
      quorum = declared_quorum(permissions: %w(member_admin), required: 2)

      expect(quorum.name).to be_nil
      expect(quorum.position).to eq(1)
    end

    it "replaces the previous description rather than appending a second stage" do
      operation.approvals permissions: %w(member_admin), required: 2
      operation.approvals actor_type: "Admin", required: 1

      expect(operation.workflow.stages.size).to eq(1)
      expect(operation.workflow.stages.first.quorums.first.threshold).to eq(1)
    end

    context "form (a): two holders of a permission" do
      subject(:quorum) { declared_quorum(permissions: %w(member_admin), required: 2) }

      it "counts to the declared threshold" do
        expect(quorum.threshold).to eq(2)
      end

      it "describes one permission row, unconstrained by actor type (§5.3)" do
        expect(quorum.permissions).to eq([permission("member_admin")])
      end

      it "names nobody in particular" do
        expect(quorum.eligible_actors).to be_empty
      end
    end

    context "form (b): one actor of a class" do
      subject(:quorum) { declared_quorum(actor_type: "Admin", required: 1) }

      it "describes one permission row constraining the type and nothing else" do
        expect(quorum.permissions).to eq([permission(nil, "Admin")])
      end

      it "counts one approval" do
        expect(quorum.threshold).to eq(1)
      end
    end

    context "form (c): one person holding both permissions" do
      subject(:quorum) do
        declared_quorum(permissions: %w(finance compliance), match: :all, required: 1)
      end

      it "describes a row per permission" do
        expect(quorum.permissions).to eq([permission("finance"), permission("compliance")])
      end

      it "carries the declared match, so both are required of the same actor" do
        expect(quorum.permission_match).to eq(:all)
      end
    end

    context "form (d): only these two people" do
      subject(:quorum) { declared_quorum(eligible_actors: [cfo, general_counsel], required: 2) }

      it "names the approvers, in the order they were declared" do
        expect(quorum.eligible_actors).to eq([cfo, general_counsel])
      end

      it "constrains eligibility by name alone" do
        expect(quorum.permissions).to be_empty
        expect(quorum.threshold).to eq(2)
      end

      # Resolving (type, id) here would call actor_attributes before the host's config file has
      # necessarily run, and would raise UnknownActorType from an initializer. Create resolves.
      it "keeps the actor objects as declared, resolving nothing" do
        expect(quorum.eligible_actors.first).to equal(cfo)
      end
    end

    context "with the hash form of permissions, which M2's op.workflow also accepts" do
      it "reads :permission and :actor_type off each entry (§5.3)" do
        quorum = declared_quorum(permissions: [{ actor_type: "Admin" }, { permission: "owner" }],
                                 required: 1)

        expect(quorum.permissions).to eq([permission(nil, "Admin"), permission("owner")])
      end

      it "accepts a bare hash, not only a hash in an array" do
        quorum = declared_quorum(permissions: { permission: "owner", actor_type: "User" },
                                 required: 1)

        expect(quorum.permissions).to eq([permission("owner", "User")])
      end
    end

    it "applies actor_type: to every permission given alongside it" do
      quorum = declared_quorum(permissions: %w(editor owner), actor_type: "User", required: 1)

      expect(quorum.permissions).to eq([permission("editor", "User"), permission("owner", "User")])
    end

    it "defaults the threshold to one approval" do
      expect(declared_quorum(permissions: %w(owner)).threshold).to eq(1)
    end

    it "resolves an undeclared match lazily from the host's default (§5.3)" do
      quorum = declared_quorum(permissions: %w(finance compliance))
      ChangeRequests.config.default_permission_match = :all

      expect(quorum.permission_match).to eq(:all)
    end

    describe "declaration-time refusals" do
      it "refuses a quorum nobody can qualify for" do
        expect { operation.approvals(required: 2) }
          .to raise_error(ChangeRequests::ConfigurationError, /permissions|actor_type|eligible_actors/)
      end

      it "refuses a threshold below one, which no approval could ever reach" do
        expect { operation.approvals(permissions: %w(owner), required: 0) }
          .to raise_error(ChangeRequests::ConfigurationError, /required/)
      end

      it "refuses a non-integer threshold" do
        expect { operation.approvals(permissions: %w(owner), required: 1.5) }
          .to raise_error(ChangeRequests::ConfigurationError, /required/)
      end

      it "refuses a match the quorum column would reject" do
        expect { operation.approvals(permissions: %w(owner), match: :either) }
          .to raise_error(ChangeRequests::ConfigurationError, /match/)
      end

      it "leaves the previous description in place when it refuses" do
        operation.approvals permissions: %w(owner), required: 2

        expect { operation.approvals(required: 3) }.to raise_error(ChangeRequests::ConfigurationError)
        expect(operation.workflow.stages.first.quorums.first.threshold).to eq(2)
      end
    end
  end
end
