# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Authorization::Callable do
  subject(:authorization) { described_class.new(policy) }

  let(:calls) { [] }
  let(:policy) do
    lambda do |**arguments|
      calls << arguments

      true
    end
  end

  let(:change_request) { build_request }
  let(:stage) { build_stage(change_request) }
  let(:quorum) { build_quorum(stage) }
  let(:actor) { Admin.create!(name: "Ada") }

  it "answers with whatever the host's policy returns" do
    expect(authorization.allows?(actor: actor, quorum: quorum)).to be(true)
  end

  it "coerces a truthy answer to a boolean, so a guard can rely on the predicate" do
    authorization = described_class.new(->(**) { "yes" })

    expect(authorization.allows?(actor: actor, quorum: quorum)).to be(true)
  end

  it "coerces nil to false" do
    authorization = described_class.new(->(**) {})

    expect(authorization.allows?(actor: actor, quorum: quorum)).to be(false)
  end

  # §9.2's documented shape. The quorum is the gem's unit of eligibility; a host policy is written
  # against the request, so the wrapper resolves both from it.
  describe "the arguments the host's lambda receives" do
    before { authorization.allows?(actor: actor, quorum: quorum, action: :reject) }

    it "passes the actor" do
      expect(calls.sole[:actor]).to equal(actor)
    end

    it "resolves the request and the stage from the quorum" do
      expect(calls.sole[:request]).to eq(change_request)
      expect(calls.sole[:stage]).to eq(stage)
    end

    it "passes the action, so one policy can answer for several commands" do
      expect(calls.sole[:action]).to eq(:reject)
    end

    it "defaults the action to :approve, which is the only one M1 asks about" do
      calls.clear
      authorization.allows?(actor: actor, quorum: quorum)

      expect(calls.sole[:action]).to eq(:approve)
    end

    it "passes nothing else, so the documented signature is the whole contract" do
      expect(calls.sole.keys).to contain_exactly(:actor, :request, :stage, :action)
    end
  end

  describe "what a host may assign to config.authorization" do
    it "wraps a bare lambda, which is what §9.2 tells hosts to write" do
      ChangeRequests.config.authorization = ->(**) { true }

      expect(ChangeRequests.config.authorization).to be_a(described_class)
    end

    it "leaves a policy object that already answers allows? alone" do
      policy = ChangeRequests::Authorization::Permissions.new
      ChangeRequests.config.authorization = policy

      expect(ChangeRequests.config.authorization).to equal(policy)
    end

    it "defaults to the permission rows (§9.2)" do
      expect(ChangeRequests::Configuration.new.authorization)
        .to be_a(ChangeRequests::Authorization::Permissions)
    end

    it "refuses something that can neither be called nor asked" do
      config = ChangeRequests::Configuration.new
      config.actor_type("User") do |type|
        type.label       = ->(user) { user.name }
        type.permissions = ->(user) { user.roles }
      end
      config.authorization = :pundit

      expect { config.validate! }.to raise_error(ChangeRequests::ConfigurationError, /authorization/)
    end
  end
end
