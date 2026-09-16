# frozen_string_literal: true

require "rails_helper"

RSpec.describe "docs/06_views_and_theming.md" do # rubocop:disable RSpec/DescribeClass
  let(:document) { File.read(File.expand_path("../../docs/06_views_and_theming.md", __dir__)) }

  # Rows of the Status table: | `status` | `tone` | tooltip |
  let(:documented_tones) do
    document.scan(/^\| `(\w+)`\s+\| `(\w+)`\s+\|/).to_h { |status, tone| [status.to_sym, tone.to_sym] }
  end

  it "documents every status with the tone the presenter gives it" do
    expect(documented_tones).to eq(ChangeRequests::RequestPresenter::STATUS_TONES)
  end

  it "names the closed tone set" do
    expect(document).to include(ChangeRequests::Value::TONES.map { |tone| "`#{tone}`" }.join(", "))
  end

  it "documents the preview limit's default" do
    expect(document).to include("config.payload_preview_limit = #{ChangeRequests::Configuration.new.payload_preview_limit}")
  end
end
