# frozen_string_literal: true

RSpec.describe ChangeRequests::Value::StageProgress do
  subject(:progress) { described_class.new(**attributes) }

  let(:quorum) do
    ChangeRequests::Value::Quorum.new(name: "owners", required: 2, approved: 1, satisfied: false, approvers: %w(Ada))
  end

  let(:attributes) do
    { name: "sign_off", position: 1, status: :pending, satisfied: false, current: true,
      satisfied_by: :any_quorum, remaining_options: ["1 more from Owners"], quorums: [quorum] }
  end

  # The point of Data here: a presenter spec asserts the whole nested structure in one expectation.
  it "compares by value, quorums included" do
    expect(progress).to eq(described_class.new(**attributes, quorums: [quorum.with(approvers: %w(Ada))]))
  end

  it "differs when a nested quorum does" do
    expect(progress).not_to eq(described_class.new(**attributes, quorums: [quorum.with(approved: 2)]))
  end

  it "answers satisfied? and current?" do
    expect([progress.satisfied?, progress.current?]).to eq([false, true])
  end

  it "falls back to humanize with no locale entry" do
    expect(progress.label).to eq("Sign off")
  end

  it "translates under change_requests.stages, the key Stage#label already reads (§5.9)" do
    with_translations("change_requests.stages.sign_off" => "Director sign-off")

    expect(progress.label).to eq("Director sign-off")
  end

  it "has no satisfied_via and no remaining options unless given them" do
    minimal = described_class.new(**attributes.except(:remaining_options))

    expect([minimal.satisfied_via, minimal.remaining_options]).to eq([nil, []])
  end

  it "freezes its collections" do
    expect([progress.quorums, progress.remaining_options]).to all(be_frozen)
  end
end
