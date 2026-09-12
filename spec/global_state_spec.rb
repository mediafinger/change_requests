# frozen_string_literal: true

# ChangeRequests.config and ChangeRequests.operations are memoised module state, so without
# spec/support/global_state.rb a registration made here is visible in every example that runs after
# it. The examples below are mirrors: whichever runs first, the other must not see its writes, so
# each pair proves isolation under any seed.
RSpec.describe GlobalState do
  def declare_operation(key)
    ChangeRequests.operations.define(key) do |op|
      op.version = "1"
      op.service = "Probes::Target"
      op.workflow { |w| w.stage :approval, permissions: %w(owner) }
    end
  end

  def register_actor_type(name)
    ChangeRequests.configure do |config|
      config.actor_type(name) do |type|
        type.label       = ->(actor) { actor.to_s }
        type.permissions = ->(_actor) { [] }
      end
    end
  end

  it "does not carry a registered actor type into the other example (1 of 2)" do
    expect(ChangeRequests.config.actor_types).not_to have_key("LeakProbeTwo")

    register_actor_type("LeakProbeOne")
  end

  it "does not carry a registered actor type into the other example (2 of 2)" do
    expect(ChangeRequests.config.actor_types).not_to have_key("LeakProbeOne")

    register_actor_type("LeakProbeTwo")
  end

  it "does not carry a declared operation into the other example (1 of 2)" do
    expect(ChangeRequests.operations.keys).not_to include("leak_probe.two")

    declare_operation("leak_probe.one")
  end

  it "does not carry a declared operation into the other example (2 of 2)" do
    expect(ChangeRequests.operations.keys).not_to include("leak_probe.one")

    declare_operation("leak_probe.two")
  end

  it "does not carry a changed setting into the other example (1 of 2)" do
    expect(ChangeRequests.config.default_permission_match).to eq(:any)
    expect(ChangeRequests.config.actor_label_strategy).to eq(:live)

    ChangeRequests.config.default_permission_match = :all
  end

  it "does not carry a changed setting into the other example (2 of 2)" do
    expect(ChangeRequests.config.actor_label_strategy).to eq(:live)
    expect(ChangeRequests.config.default_permission_match).to eq(:any)

    ChangeRequests.config.actor_label_strategy = :snapshot
  end
end
