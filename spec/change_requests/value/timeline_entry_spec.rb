# frozen_string_literal: true

RSpec.describe ChangeRequests::Value::TimelineEntry do
  subject(:entry) { described_class.new(**attributes) }

  let(:actor) { ChangeRequests::ActorRef.new(type: "Admin", id: "42", label: "Ada Lovelace") }
  let(:occurred_at) { Time.utc(2026, 9, 9, 10, 3, 41) }

  let(:attributes) do
    { kind: :requested, actor: actor, occurred_at: occurred_at, operation_version: "2026-09-09" }
  end

  it "compares by value, the actor included" do
    expect(entry).to eq(described_class.new(**attributes,
                                            actor: ChangeRequests::ActorRef.new(type: "Admin", id: "42",
                                                                                label: "Ada Lovelace")))
  end

  it "falls back to humanize with no locale entry" do
    expect(described_class.new(**attributes, kind: :quorum_satisfied).label).to eq("Quorum satisfied")
  end

  # Not change_requests.events: that key already holds the body the gem writes for its own events.
  it "translates under change_requests.timeline" do
    with_translations("change_requests.timeline.requested" => "Raised")

    expect(entry.label).to eq("Raised")
  end

  it "has no body and empty metadata unless given them" do
    expect([entry.body, entry.metadata]).to eq([nil, {}])
  end

  it "freezes its metadata" do
    expect(described_class.new(**attributes, metadata: { stage: "sign_off" }).metadata).to be_frozen
  end
end
