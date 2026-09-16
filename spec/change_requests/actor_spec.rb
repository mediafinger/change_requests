# frozen_string_literal: true

require "rails_helper"

# Included into the dummy's models here rather than in the dummy app itself: the concern is
# optional, and the dummy app proving it works without it is worth as much as this proving it works
# with it.
class ActorProbeUser < User
  include ChangeRequests::Actor

  self.table_name = "users"
end

class UnregisteredProbe < User
  include ChangeRequests::Actor

  self.table_name = "users"
end

RSpec.describe ChangeRequests::Actor do
  subject(:user) { ActorProbeUser.create!(name: "Alice", email: "alice@example.com") }

  let(:someone_else) { User.create!(name: "Bob", email: "bob@example.com") }

  before do
    ChangeRequests.config.actor_type("ActorProbeUser") do |t|
      t.key_type    = :uuid
      t.label       = ->(record) { record.name }
      t.permissions = ->(record) { record.roles }
    end

    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version = "2026-09-16"
      op.service = "Members::UpdateRoles"
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
    end
  end

  def raise_request(requester)
    ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester)
  end

  describe "#change_requests" do
    it "is the requests this actor raised" do
      mine = raise_request(user)
      raise_request(someone_else)

      expect(user.change_requests).to eq([mine])
    end

    it "matches calling the scope directly" do
      raise_request(user)

      expect(user.change_requests.to_a).to eq(ChangeRequests::Request.requested_by(user).to_a)
    end

    it "is empty for an actor who raised nothing" do
      raise_request(someone_else)

      expect(user.change_requests).to be_empty
    end

    it "is a scope, so a host can keep narrowing it" do
      raise_request(user).update!(status: "canceled")
      open = raise_request(user)

      expect(user.change_requests.where(status: "pending")).to eq([open])
    end
  end

  describe "#change_requests_visible" do
    it "matches calling visible_to directly" do
      raise_request(user)
      raise_request(someone_else)

      expect(user.change_requests_visible.to_a).to eq(ChangeRequests::Request.visible_to(user).to_a)
    end

    # visible_to is not "mine": under the identity scope it is everything with a live declaration.
    it "includes requests raised by others when visibility allows it" do
      theirs = raise_request(someone_else)

      expect(user.change_requests_visible).to include(theirs)
    end
  end

  describe "#may_request_change_requests?" do
    it "answers what the registered type declares" do
      expect(user.may_request_change_requests?).to be(true)
    end

    it "follows the registration when it changes" do
      ChangeRequests.config.actor_types["ActorProbeUser"].may_request = false

      expect(user.may_request_change_requests?).to be(false)
    end
  end

  # The class may be registered in an initializer that has not run yet, so including the concern
  # must not require the registration - using it must.
  describe "a class that is not registered" do
    it "loads, since the include itself checks nothing" do
      expect(UnregisteredProbe.include?(described_class)).to be(true)
    end

    it "is refused on first use, naming the class" do
      stranger = UnregisteredProbe.create!(name: "Stranger", email: "stranger@example.com")

      expect { stranger.change_requests.to_a }
        .to raise_error(ChangeRequests::UnknownActorType, /UnregisteredProbe/)
      expect { stranger.may_request_change_requests? }
        .to raise_error(ChangeRequests::UnknownActorType, /UnregisteredProbe/)
    end
  end

  # It is a convenience a host opts into; the gem's own code must work without it. Comments are
  # skipped - explaining the concern is not depending on it.
  it "is required by nothing inside the gem" do
    code = lambda do |file|
      File.readlines(file).reject { |line| line.lstrip.start_with?("#") }.join
    end

    references = Dir[File.expand_path("../../lib/**/*.rb", __dir__)]
                 .reject { |file| file.end_with?("change_requests/actor.rb") }
                 .select { |file| code.call(file).match?(/\bChangeRequests::Actor\b|\binclude Actor\b/) }

    expect(references).to be_empty
  end

  it "registers nothing, so the registry is the only place a type is declared" do
    before = ChangeRequests.config.actor_types.keys
    Class.new(User) { include ChangeRequests::Actor }

    expect(ChangeRequests.config.actor_types.keys).to eq(before)
  end
end
