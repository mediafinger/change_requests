# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests do
  it "has a version number" do
    expect(ChangeRequests::VERSION).not_to be_nil
  end

  describe ".request!" do
    subject(:change_request) { described_class.request!("members.update_roles", **arguments) }

    let(:arguments) { { payload: payload, requester: requester } }
    let(:requester) { Admin.create!(name: "Ada") }
    let(:payload) { { "member_id" => "42", "roles" => %w(editor) } }

    before do
      described_class.operations.define("members.update_roles") do |op|
        op.version = "2026-09-12"
        op.service = "Members::UpdateRoles"
        op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 2 }
      end
    end

    it "returns the request it recorded" do
      expect(change_request).to be_a(ChangeRequests::Request)
      expect(change_request).to be_persisted
    end

    # §6.5 is what every host writes, and it reads better with the key up front - which is the
    # whole reason this exists beside Commands::Create's all-keyword shape.
    it "takes the operation key positionally" do
      expect(change_request.operation_key).to eq("members.update_roles")
    end

    it "defaults the payload to an empty object, as Create does" do
      request = described_class.request!("members.update_roles", requester: requester)

      expect(request.payload).to eq({})
    end

    it "leaves the tenant columns null when none is passed" do
      expect(change_request.tenant).to be_nil
    end

    it "passes a tenant through" do
      organization = Organization.create!(name: "Acme")

      request = described_class.request!("members.update_roles", **arguments, tenant: organization)

      expect(request.tenant).to eq(type: "Organization", id: organization.id.to_s, label: "Acme")
    end

    # §6.5's example verbatim: the call is identical however elaborate the workflow is, because
    # thresholds, permissions and stages come from the operation and never from the caller.
    it "materialises the declared workflow without the caller naming any of it" do
      expect(change_request.stages.sole.quorums.sole)
        .to have_attributes(threshold: 2, permission_match: "any")
    end

    describe "against Commands::Create" do
      it "produces an identical row for identical input" do
        direct = ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                                       requester: requester, payload: payload)

        expect(attributes(change_request)).to eq(attributes(direct))
      end

      it "materialises an identical row graph" do
        direct = ChangeRequests::Commands::Create.call(operation_key: "members.update_roles",
                                                       requester: requester, payload: payload)

        expect(graph(change_request)).to eq(graph(direct))
      end

      def attributes(request)
        request.attributes.except("id", "created_at", "updated_at", "lock_version", "expires_at")
      end

      def graph(request)
        request.stages.order(:position).map do |stage|
          [stage.name, stage.satisfied_by,
           stage.quorums.order(:position).map { |quorum| [quorum.name, quorum.threshold] }]
        end
      end
    end

    # Nothing is rescued and re-raised: the wrapper adds a call shape and nothing else (§7).
    describe "the error taxonomy, unchanged from Create's" do
      it "raises UnknownOperation for a key with no live declaration (§5.11)" do
        described_class.operations.clear

        expect { change_request }
          .to raise_error(ChangeRequests::UnknownOperation, /members\.update_roles/)
      end

      it "raises ConfigurationError for a declaration that cannot be requested (§6.12)" do
        described_class.operations["members.update_roles"].service = nil

        expect { change_request }.to raise_error(ChangeRequests::ConfigurationError, /service/)
      end

      it "raises InvalidPayload for a payload that is not a JSON object" do
        expect { described_class.request!("members.update_roles", payload: [], requester: requester) }
          .to raise_error(ChangeRequests::InvalidPayload)
      end

      it "raises NotAuthorized for an actor type that may not request (§19.4)" do
        described_class.config.actor_types["Admin"].may_request = false

        expect { change_request }.to raise_error(ChangeRequests::NotAuthorized) { |error|
          expect(error.reason).to eq(:may_not_request)
        }
      end

      it "raises UnknownActorType for a requester whose class is not registered (§9.1)" do
        expect { described_class.request!("members.update_roles", requester: Object.new) }
          .to raise_error(ChangeRequests::UnknownActorType)
      end
    end
  end
end
