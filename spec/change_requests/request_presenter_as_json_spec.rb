# frozen_string_literal: true

require "rails_helper"

module JsonContractProbes
  class Target
    def self.call(**); end
  end

  # What an engine's url helpers answer, for every member action.
  class Routes
    %i(approve unapprove reject execute cancel comment).each do |name|
      define_method(:"#{name}_request_path") { |request| "/change_requests/requests/#{request.id}/#{name}" }
    end
  end

  DOCUMENT = File.expand_path("../../docs/06_views_and_theming.md", __dir__)
  GOLDEN = File.expand_path("../fixtures/json_contract/request.json", __dir__)
  UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/

  # Passed through verbatim, so their insides are the host's, not the contract's.
  OPAQUE = %w(payload timeline[].metadata).freeze

  module_function

  # { "stages[].quorums[].name" => Set["string", "null"] } for everything a JSON document holds.
  def key_types(node, prefix = nil, into = Hash.new { |hash, key| hash[key] = Set.new })
    return into unless node.is_a?(Hash)

    node.each do |key, value|
      path = [prefix, key].compact.join(".")
      into[path] << type_of(value)

      next if OPAQUE.include?(path)

      key_types(value, path, into) if value.is_a?(Hash)
      value.each { |element| key_types(element, "#{path}[]", into) } if value.is_a?(Array)
    end

    into
  end

  def type_of(value)
    case value
    when nil then "null"
    when true, false then "boolean"
    when Integer then "integer"
    when String then "string"
    when Array then "array"
    when Hash then "object"
    else value.class.name
    end
  end
end

# M5-7: `as_json` is a documented, versioned contract (§11, §17.1, Q5). The document, the code and a golden
# file are held to each other, so none of the three can change alone.
RSpec.describe ChangeRequests::RequestPresenter, "#as_json" do
  include ActiveSupport::Testing::TimeHelpers

  let(:document) { File.read(JsonContractProbes::DOCUMENT) }

  let(:documented) do
    table = document[/<!-- contract: keys -->\n(.*?)\n\n/m, 1]

    table.scan(/^\| `([^`]+)`\s*\| ([^|]+?)\s*\|$/).to_h { |key, types| [key, types.split(", ").to_set] }
  end

  let(:requester) { Manager.create!(id: "mgr-rita", name: "Rita") }
  let(:grace) { Manager.create!(id: "mgr-grace", name: "Grace Hopper", roles: %w(owner)) }
  let(:edith) { Manager.create!(id: "mgr-edith", name: "Edith Clarke", roles: %w(owner)) }
  let(:dora) { Manager.create!(id: "mgr-dora", name: "Dora", roles: %w(director)) }
  let(:organization) { Organization.create!(name: "Acme") }

  before do
    ChangeRequests.config.actor_types.fetch("Manager").path = ->(manager, _routes) { "/managers/#{manager.id}" }

    ChangeRequests.operations.define("members.update_roles") do |op|
      op.version        = "2026-09-09"
      op.service        = "JsonContractProbes::Target"
      op.expires_in     = 7.days
      op.payload_labels = ->(payload) { { member_id: "Member #{payload["member_id"]}" } }
      op.override(permissions: %w(security_officer), require_reason: true)
      op.workflow do |w|
        w.stage :operational, satisfied_by: :any_quorum do |q|
          q.quorum :admins, permissions: %w(admin), threshold: 1
          q.quorum :owners, permissions: %w(owner), threshold: 2
        end
        w.stage :sign_off, permissions: %w(director), threshold: 1
      end
    end
  end

  def at(minute, &)
    travel_to(Time.utc(2026, 9, 9, 10, minute, 0), &)
  end

  # Every section populated: two stages, an OR-stage closed through one route, a comment, an execution,
  # a tenant, payload labels, an override on offer, and paths throughout.
  def executed_request
    request = at(0) do
      ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester,
                                            tenant: organization, payload: { "member_id" => "42", "roles" => %w(editor) })
    end
    at(1) { ChangeRequests::Commands::Approve.call(request: request, actor: grace) }
    at(2) { ChangeRequests::Commands::Comment.call(request: request, actor: requester, body: "Please hurry") }
    at(3) { ChangeRequests::Commands::Approve.call(request: request, actor: edith) }
    at(4) { ChangeRequests::Commands::Approve.call(request: request, actor: dora) }
    at(5) { ChangeRequests::Commands::Execute.call(request: request, actor: grace) }

    request.reload
  end

  def pending_request
    at(0) { ChangeRequests::Commands::Create.call(operation_key: "members.update_roles", requester: requester) }
  end

  def json_of(request, **)
    at(6) { described_class.new(request, actor: grace, **).as_json }
  end

  def rich
    json_of(executed_request, routes: JsonContractProbes::Routes.new)
  end

  def sparse
    json_of(pending_request, resolve_actors: false)
  end

  def normalized(json)
    JSON.parse(JSON.generate(json).gsub(JsonContractProbes::UUID, "<uuid>"))
  end

  describe "against the document" do
    it "produces exactly the documented keys" do
      produced = JsonContractProbes.key_types(rich).keys | JsonContractProbes.key_types(sparse).keys

      expect(produced).to match_array(documented.keys)
    end

    it "gives every key a value of a documented type" do
      [rich, sparse].each do |json|
        JsonContractProbes.key_types(json).each do |key, types|
          allowed = documented.fetch(key)

          expect(allowed.include?("any") || types <= allowed).to be(true), "#{key}: #{types.to_a} not in #{allowed.to_a}"
        end
      end
    end

    it "shows an example with exactly the documented keys" do
      example = JSON.parse(document[/<!-- contract: example -->\n```json\n(.*?)```/m, 1])

      expect(JsonContractProbes.key_types(example).keys).to match_array(documented.keys)
    end

    it "states the schema version the code produces" do
      expect(document).to include("`schema_version` is `#{ChangeRequests::JsonContract::SCHEMA_VERSION}`")
    end
  end

  describe "the value rules" do
    subject(:json) { rich }

    it "is schema_version 1" do
      expect(json["schema_version"]).to eq(1)
    end

    it "uses string keys throughout, as JSON has no symbols" do
      expect(JSON.parse(JSON.generate(json))).to eq(json)
    end

    it "renders every timestamp as ISO8601 UTC with a Z" do
      stamps = json.values_at("created_at", "expires_at", "executed_at") + json["timeline"].pluck("occurred_at")

      expect(stamps).to all(match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/))
    end

    it "renders ids as strings" do
      expect([json["id"], json["requester"]["id"], json["tenant"]["id"]]).to all(be_a(String))
    end

    it "renders enums as strings" do
      enums = [json["status"]["key"], json["status"]["tone"]] +
              json["stages"].flat_map { |stage| stage.values_at("status", "satisfied_by") } +
              json["actions"].flat_map { |action| action.values_at("name", "method", "tone") } +
              json["timeline"].pluck("kind")

      expect(enums).to all(be_a(String))
    end

    it "keeps every documented key present when its value is null" do
      expect(sparse).to include("executer" => nil, "tenant" => nil, "executed_at" => nil, "overridden_at" => nil)
      expect(sparse["actions"].map(&:keys).uniq.sole).to include("path", "confirm", "reason")
    end
  end

  describe "without routes or actor resolution" do
    subject(:json) { sparse }

    it "still produces valid JSON" do
      expect(JSON.parse(JSON.generate(json))).to eq(json)
    end

    it "has a null path everywhere" do
      paths = [json["requester"]["path"]] + json["actions"].pluck("path") +
              json["timeline"].map { |entry| entry["actor"]["path"] }

      expect(paths).to all(be_nil)
    end
  end

  # One fixture request, rendered and compared to a checked-in file: a contract change is a diff in review.
  # Regenerate deliberately with UPDATE_GOLDEN=1, and bump schema_version if a key went or changed type.
  it "matches the golden file" do
    produced = normalized(rich)
    File.write(JsonContractProbes::GOLDEN, "#{JSON.pretty_generate(produced)}\n") if ENV["UPDATE_GOLDEN"]

    expect(produced).to eq(JSON.parse(File.read(JsonContractProbes::GOLDEN)))
  end
end
