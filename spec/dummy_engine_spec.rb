# frozen_string_literal: true

require "rails_helper"

# Regression: the dummy application booted without the engine.
#
# `require "change_requests"` decides once, at require time, whether to load the Rails layer - and
# `spec_helper` requires the gem before anything has loaded Rails, so the answer was "no". By the
# time `rails_helper` booted the dummy app, the second `require` was a no-op and the engine never
# arrived. Everything the engine contributes was therefore inert in the one application this suite
# tests against: `isolate_namespace`, the boot-time `validate!`, the route set, and from M6 the
# controllers and views.
#
# It passed unnoticed because the checks that would have caught it each loaded Rails themselves
# first, which is the order a real host uses and the order this suite does not.
#
# Described by name rather than by constant on purpose: if the engine fails to load again, this file
# should report five clear failures, not raise a NameError while RSpec is still loading it.
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

  # The engine installs `table_name_prefix` unless the module already answers to one, and its
  # version yields `change_requests_stages` rather than §4's `change_request_stages`. This is the
  # assertion M0-5 owed M0-2, made where it actually matters: inside a booted application.
  it "did not overwrite the table name prefix" do
    expect(ChangeRequests.table_name_prefix).to eq("change_request_")
  end

  it "contributes its route set" do
    expect(ChangeRequests::Engine.routes).to be_a(ActionDispatch::Routing::RouteSet)
  end
end
