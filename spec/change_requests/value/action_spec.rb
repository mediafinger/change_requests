# frozen_string_literal: true

RSpec.describe ChangeRequests::Value::Action do
  subject(:action) { described_class.new(name: :approve, enabled: true) }

  it "compares by value" do
    expect(action).to eq(described_class.new(name: :approve, enabled: true))
  end

  it "falls back to humanize with no locale entry" do
    expect(described_class.new(name: :request_changes, enabled: true).label).to eq("Request changes")
  end

  it "translates under change_requests.actions" do
    with_translations("change_requests.actions.request_changes" => "Send back")

    expect(described_class.new(name: :request_changes, enabled: true).label).to eq("Send back")
  end

  it "defaults to a neutral POST with nothing to confirm, no path and no reason" do
    expect(action.to_h.slice(:http_method, :tone, :confirm, :path, :reason, :requires_reason))
      .to eq(http_method: :post, tone: :neutral, confirm: nil, path: nil, reason: nil, requires_reason: false)
  end

  # No ActionView: a path is whatever string the caller built, or nothing (§11).
  it "carries a path as the string it was given" do
    expect(described_class.new(name: :approve, enabled: true, path: "/change_requests/1/approve").path)
      .to eq("/change_requests/1/approve")
  end

  it "leaves Object#method alone" do
    expect(action.method(:label).call).to eq("Approve")
  end

  it "refuses a tone outside the closed set" do
    expect { described_class.new(name: :approve, enabled: true, tone: :loud) }.to raise_error(ArgumentError)
  end
end
