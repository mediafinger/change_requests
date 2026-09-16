# frozen_string_literal: true

RSpec.describe ChangeRequests::Value::Field do
  it "compares by value" do
    built_elsewhere = [:roles, %w(editor)].then { |key, value| described_class.new(key: key, value: value) }

    expect(described_class.new(key: :roles, value: %w(editor))).to eq(built_elsewhere)
  end

  it "differs when any member does" do
    expect(described_class.new(key: :roles, value: %w(editor)))
      .not_to eq(described_class.new(key: :roles, value: %w(owner)))
  end

  it "falls back to humanize with no locale entry" do
    expect(described_class.new(key: :member_id, value: "42").label).to eq("Member")
  end

  it "translates under change_requests.fields" do
    with_translations("change_requests.fields.member_id" => "Team member")

    expect(described_class.new(key: :member_id, value: "42").label).to eq("Team member")
  end

  it "keeps a label the caller supplied" do
    expect(described_class.new(key: :member_id, label: "Who", value: "42").label).to eq("Who")
  end

  it "builds positionally, as Data allows" do
    expect(described_class.new(:roles, nil, "editor").label).to eq("Roles")
  end
end
