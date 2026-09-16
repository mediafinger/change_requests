# frozen_string_literal: true

RSpec.describe ChangeRequests::Value::Quorum do
  subject(:quorum) do
    described_class.new(name: "owners", required: 2, approved: 2, satisfied: true, approvers: %w(Ada Grace))
  end

  it "compares by value" do
    expect(quorum).to eq(described_class.new(name: "owners", required: 2, approved: 2, satisfied: true,
                                             approvers: %w(Ada Grace)))
  end

  it "answers satisfied?" do
    expect(quorum).to be_satisfied
  end

  it "falls back to humanize with no locale entry" do
    expect(quorum.label).to eq("Owners")
  end

  it "translates under change_requests.quorums, the key Quorum#label already reads (§5.9)" do
    with_translations("change_requests.quorums.owners" => "Account owners")

    expect(quorum.label).to eq("Account owners")
  end

  it "has no approvers unless given some" do
    expect(described_class.new(name: "owners", required: 1, approved: 0, satisfied: false).approvers).to eq([])
  end

  it "freezes its approvers, so the value cannot change under a caller" do
    expect(quorum.approvers).to be_frozen
  end

  describe "a nameless quorum" do
    it "takes the label it is given, which is its stage's" do
      nameless = described_class.new(name: nil, label: "Director sign-off", required: 1, approved: 0,
                                     satisfied: false)

      expect(nameless.label).to eq("Director sign-off")
    end

    # Humanizing nil would render an empty heading; the presenter has the stage label to hand.
    it "refuses to be built without one" do
      expect { described_class.new(name: nil, required: 1, approved: 0, satisfied: false) }
        .to raise_error(ArgumentError, /stage's label/)
    end
  end
end
