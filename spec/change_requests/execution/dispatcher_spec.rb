# frozen_string_literal: true

require "rails_helper"

# Real targets, because the contract is about what a declared constant actually answers.
module DispatchProbes
  class Keywords
    def self.call(member_id:, roles: [])
      { member_id: member_id, roles: roles }
    end
  end

  class WantsId
    def self.call(member_id:, change_request_id:)
      { member_id: member_id, id: change_request_id }
    end
  end

  class Forwarding
    def self.call(**options)
      options
    end
  end

  class Renamed
    def self.perform(**options)
      { performed: options }
    end
  end

  class TakesABlock
    def self.call(member_id:, &)
      { member_id: member_id }
    end
  end

  class NoArguments
    def self.call
      :done
    end
  end

  class Positional
    def self.call(member_id)
      member_id
    end
  end

  class OptionalPositional
    def self.call(member_id = nil, **)
      member_id
    end
  end

  class Splatted
    def self.call(*arguments, **options)
      [arguments, options]
    end
  end

  class InstanceOnly
    def call(**)
      :done
    end
  end

  class PrivateSingleton
    class << self
      private

      def call(**)
        :done
      end
    end
  end
end

RSpec.describe ChangeRequests::Execution::Dispatcher do
  subject(:dispatch) do
    described_class.call(operation_key: "members.update_roles", payload: payload,
                         change_request_id: change_request_id)
  end

  let(:payload) { { "member_id" => "42" } }
  let(:change_request_id) { "11111111-2222-3333-4444-555555555555" }

  def declare(service:, method_name: :call, key: "members.update_roles")
    ChangeRequests.operations.define(key) do |op|
      op.version     = "2026-09-12"
      op.service     = service
      op.method_name = method_name
      op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
    end
  end

  describe "resolving the target" do
    it "returns whatever the target returns" do
      declare(service: "DispatchProbes::Keywords")

      expect(dispatch).to eq(member_id: "42", roles: [])
    end

    it "calls the declared method_name rather than :call" do
      declare(service: "DispatchProbes::Renamed", method_name: :perform)

      expect(dispatch).to eq(performed: { member_id: "42", change_request_id: change_request_id })
    end

    # §6.12 point 1: the columns are audit data, not dispatch input. This takes a key, not a row.
    it "dispatches to the declaration even when a request row says otherwise" do
      declare(service: "DispatchProbes::Renamed", method_name: :perform)
      request = ChangeRequests::Commands::Create.call(
        operation_key: "members.update_roles", requester: Admin.create!(name: "Ada"), payload: payload
      )
      declare(service: "DispatchProbes::Forwarding")

      expect(request.service).to eq("DispatchProbes::Renamed")
      expect(described_class.call(operation_key: request.operation_key, payload: request.payload,
                                  change_request_id: request.id))
        .to eq(member_id: "42", change_request_id: request.id)
    end

    it "raises UnknownOperation for a key with no live declaration (§5.11)" do
      expect { dispatch }
        .to raise_error(ChangeRequests::UnknownOperation, /members\.update_roles/)
    end

    # Nothing is constantized on that path: there is no declaration to read a service name from.
    it "names no constant when it refuses an undeclared key" do
      declare(service: "DispatchProbes::Keywords")
      ChangeRequests.operations.clear

      expect { dispatch }.to raise_error(ChangeRequests::UnknownOperation) { |error|
        expect(error.message).not_to include("DispatchProbes")
      }
    end
  end

  describe "the payload" do
    it "symbolises the top level, so a string key arrives as a keyword argument (§6.12)" do
      declare(service: "DispatchProbes::Keywords")

      expect(dispatch).to eq(member_id: "42", roles: [])
    end

    it "leaves nested keys as strings, a target taking one should expect them" do
      declare(service: "DispatchProbes::Keywords")

      result = described_class.call(operation_key: "members.update_roles",
                                    payload: { "member_id" => "42", "roles" => { "editor" => true } },
                                    change_request_id: change_request_id)

      expect(result).to eq(member_id: "42", roles: { "editor" => true })
    end

    it "dispatches an empty payload as no keywords at all" do
      declare(service: "DispatchProbes::NoArguments")

      expect(described_class.call(operation_key: "members.update_roles",
                                  change_request_id: change_request_id)).to eq(:done)
    end

    it "refuses a payload that is not a JSON object" do
      declare(service: "DispatchProbes::Forwarding")

      expect do
        described_class.call(operation_key: "members.update_roles", payload: [],
                             change_request_id: change_request_id)
      end
        .to raise_error(ChangeRequests::InvalidPayload)
    end

    # §6.12: matching the payload to the target's signature is the host's responsibility, and a
    # mismatch surfaces as an ArgumentError recorded like any other target failure.
    it "lets an unknown keyword surface as the target's own ArgumentError" do
      declare(service: "DispatchProbes::Keywords")

      expect do
        described_class.call(operation_key: "members.update_roles",
                             payload: { "member_id" => "42", "nope" => 1 },
                             change_request_id: change_request_id)
      end
        .to raise_error(ArgumentError, /unknown keyword: :nope/)
    end
  end

  describe "change_request_id (§8)" do
    it "passes it to a target that declares the keyword" do
      declare(service: "DispatchProbes::WantsId")

      expect(dispatch).to eq(member_id: "42", id: change_request_id)
    end

    it "passes it to a target that forwards everything, which is not broken by receiving it" do
      declare(service: "DispatchProbes::Forwarding")

      expect(described_class.call(operation_key: "members.update_roles", change_request_id: "abc"))
        .to eq(change_request_id: "abc")
    end

    it "withholds it from a target that declares neither, which would otherwise break" do
      declare(service: "DispatchProbes::Keywords")

      expect(dispatch).to eq(member_id: "42", roles: [])
    end

    # It is the identity the gem guarantees is stable across every attempt (§8), so it outranks a
    # payload key that happens to share its name.
    it "outranks a payload key of the same name" do
      declare(service: "DispatchProbes::Forwarding")

      result = described_class.call(operation_key: "members.update_roles",
                                    payload: { "change_request_id" => "from-the-payload" },
                                    change_request_id: "the-real-one")

      expect(result).to eq(change_request_id: "the-real-one")
    end
  end

  describe "the target contract, asserted (§6.12)" do
    it "refuses a target taking a required positional argument, naming the contract" do
      declare(service: "DispatchProbes::Positional")

      expect { dispatch }.to raise_error(ChangeRequests::ConfigurationError) { |error|
        expect(error.message).to include("DispatchProbes::Positional.call takes positional arguments")
        expect(error.message).to include("keyword arguments only")
      }
    end

    it "refuses an optional positional argument too, the contract being keywords only" do
      declare(service: "DispatchProbes::OptionalPositional")

      expect { dispatch }.to raise_error(ChangeRequests::ConfigurationError, /positional/)
    end

    it "refuses a splat, which accepts positionally even though it need not" do
      declare(service: "DispatchProbes::Splatted")

      expect { dispatch }.to raise_error(ChangeRequests::ConfigurationError, /positional/)
    end

    it "accepts a block parameter, which is not positional in the sense that matters" do
      declare(service: "DispatchProbes::TakesABlock")

      expect(dispatch).to eq(member_id: "42")
    end

    it "refuses a target answering the method only as an instance method" do
      declare(service: "DispatchProbes::InstanceOnly")

      expect { dispatch }
        .to raise_error(ChangeRequests::ConfigurationError, /does not answer \.call/)
    end

    it "refuses a private singleton method, dispatch using public_send" do
      declare(service: "DispatchProbes::PrivateSingleton")

      expect { dispatch }
        .to raise_error(ChangeRequests::ConfigurationError, /does not answer \.call/)
    end

    it "refuses a service that does not resolve to a constant" do
      declare(service: "DispatchProbes::NoSuchThing")

      expect { dispatch }
        .to raise_error(ChangeRequests::ConfigurationError, /does not resolve to a constant/)
    end

    # The same words either way, both reading Execution::TargetContract - so a host is not told one
    # thing by `rake change_requests:verify` and another by the execution that follows.
    it "refuses in the same words verify! does" do
      declare(service: "DispatchProbes::Positional")

      expect { dispatch }.to raise_error(ChangeRequests::ConfigurationError) { |error|
        expect(ChangeRequests.operations.problems.join).to include(error.message)
      }
    end
  end
end
