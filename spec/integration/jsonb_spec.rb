# frozen_string_literal: true

require "rails_helper"

ProbeTable.create!(:jsonb_probes)

class JsonbProbe < ChangeRequests::Record
  self.table_name = "jsonb_probes"
end

# payload, payload_labels and event metadata are jsonb, so a broken round-trip breaks most of
# Milestone 1. Not hypothetical: ActiveSupport 8.1.3.1 calls JSON.parse positionally, json 3 removed
# that form, and every jsonb read raises ArgumentError. The Gemfile pins json to 2.x; this fails if
# that stops being enough.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "jsonb columns" do
  it "reads back an empty default" do
    expect(JsonbProbe.create!.reload.payload).to eq({})
  end

  it "round-trips a written object" do
    probe = JsonbProbe.create!(payload: { "member_id" => 7, "roles" => %w(editor) })

    expect(probe.reload.payload).to eq("member_id" => 7, "roles" => %w(editor))
  end

  # §6.12: symbolisation is top-level only, and jsonb normalises - integers, floats, booleans and
  # null round-trip as themselves, symbols and dates do not.
  it "returns string keys, whatever went in" do
    probe = JsonbProbe.create!(payload: { member_id: 7 })

    expect(probe.reload.payload.keys).to eq(["member_id"])
  end

  it "preserves scalar types rather than stringifying them" do
    probe = JsonbProbe.create!(payload: { "n" => 7, "f" => 1.5, "t" => true, "nil" => nil })

    expect(probe.reload.payload).to eq("n" => 7, "f" => 1.5, "t" => true, "nil" => nil)
  end

  it "handles a nested structure, whose inner keys stay strings" do
    probe = JsonbProbe.create!(payload: { "outer" => { "inner" => [1, 2] } })

    expect(probe.reload.payload).to eq("outer" => { "inner" => [1, 2] })
  end
end
