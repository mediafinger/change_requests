# frozen_string_literal: true

require "rails_helper"

# Regression: the dummy app booted with no engine, because spec_helper requires the gem before Rails
# exists and `require` only decides once. Everything the engine contributes was inert.
#
# Described by name, not constant: a regression should fail five examples, not raise NameError while
# RSpec loads the file.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "the engine, inside the dummy application" do
  it "is loaded" do
    expect(defined?(ChangeRequests::Engine)).to eq("constant")
  end

  it "isolated the namespace, so nothing leaks into the host" do
    expect(ChangeRequests::Engine).to be_isolated
  end

  it "is registered with the application, not merely defined" do
    expect(Rails.application.railties.map(&:class)).to include(ChangeRequests::Engine)
  end

  # Inside a booted application, where isolate_namespace has actually run.
  it "did not overwrite the table name prefix" do
    expect(ChangeRequests.table_name_prefix).to eq("change_request_")
  end

  it "contributes its route set" do
    expect(ChangeRequests::Engine.routes).to be_a(ActionDispatch::Routing::RouteSet)
  end
end
