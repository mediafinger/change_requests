# frozen_string_literal: true

RSpec.describe ChangeRequests::Value::Status do
  subject(:status) { described_class.new(key: :failed, tone: :danger, tooltip: "Timeout calling provider") }

  it "compares by value" do
    expect(status).to eq(described_class.new(key: :failed, tone: :danger, tooltip: "Timeout calling provider"))
  end

  it "falls back to humanize with no locale entry" do
    expect(status.label).to eq("Failed")
  end

  it "translates under change_requests.statuses" do
    with_translations("change_requests.statuses.failed" => "Did not run")

    expect(status.label).to eq("Did not run")
  end

  it "has no tooltip unless given one" do
    expect(described_class.new(key: :pending, tone: :neutral).tooltip).to be_nil
  end

  it "stores the tone as a symbol" do
    expect(described_class.new(key: :failed, tone: "danger").tone).to eq(:danger)
  end

  it "refuses a tone outside the closed set" do
    expect { described_class.new(key: :failed, tone: :red) }.to raise_error(ArgumentError, /:red/)
  end
end
