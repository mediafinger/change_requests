# frozen_string_literal: true

RSpec.describe ChangeRequests::Workflow do
  subject(:workflow) { described_class.new([stage]) }

  let(:stage) do
    described_class::Stage.new(name: "approval", position: 1, satisfied_by: :any_quorum,
                               quorums: [quorum])
  end

  let(:quorum) do
    described_class::Quorum.new(name: nil, position: 1, threshold: 2, permission_match: :all,
                                permissions: [described_class::Permission.new(permission: "owner",
                                                                              actor_type: nil)],
                                eligible_actors: [])
  end

  it "starts empty, and says so" do
    expect(described_class.new).to be_empty
  end

  it "holds the stages it was built with" do
    expect(workflow.stages).to eq([stage])
    expect(workflow).not_to be_empty
  end

  # The description is compared, not identified: two declarations of the same policy are the same
  # policy, which is what makes the M1b-0 acceptance assertions readable.
  describe "value equality" do
    let(:owners) { described_class::Permission.new(permission: "owner", actor_type: nil) }

    it "compares permissions by their two columns" do
      expect(owners).to eq(described_class::Permission.new(**owners.to_h))
    end

    it "distinguishes a permission from the same permission constrained by type" do
      expect(owners).not_to eq(owners.with(actor_type: "User"))
    end
  end

  describe "Quorum#permission_match" do
    it "keeps a declared match" do
      expect(quorum.permission_match).to eq(:all)
    end

    it "falls back to the host's default when none was declared (§5.3)" do
      ChangeRequests.config.default_permission_match = :all

      expect(quorum.with(permission_match: nil).permission_match).to eq(:all)
    end
  end
end
