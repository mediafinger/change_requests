# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Record do
  # §4's nine tables, as constant => table name. Listed in full from M1a-1 so that a model arriving
  # in M1a-3 onwards cannot quietly derive the wrong name: each pair asserts itself the moment the
  # constant exists, and reports as pending until then.
  #
  # This is the acceptance M1a-1 owes - "a rename cannot pass silently" - written so it does not
  # have to wait for the models it is about.
  def self.nine_tables
    {
      "Request" => "change_requests",
      "Stage" => "change_request_stages",
      "Quorum" => "change_request_quorums",
      "QuorumPermission" => "change_request_quorum_permissions",
      "QuorumEligibleActor" => "change_request_quorum_eligible_actors",
      "Approval" => "change_request_approvals",
      "ApprovalQuorum" => "change_request_approval_quorums",
      "Event" => "change_request_events",
      "Attempt" => "change_request_attempts",
    }.freeze
  end

  describe "the abstract base" do
    it "is abstract, so it never looks for a table of its own" do
      expect(described_class.abstract_class?).to be(true)
    end

    # §1: the domain core loads against a bare ActiveRecord connection with Rails undefined, which a
    # host's ApplicationRecord cannot promise.
    it "inherits from ActiveRecord::Base rather than a host's ApplicationRecord" do
      expect(described_class.superclass).to eq(ActiveRecord::Base)
    end
  end

  describe "derived table names" do
    nine_tables.each do |constant, table_name|
      it "gives #{constant} the table #{table_name}" do
        skip "ChangeRequests::#{constant} arrives with a later M1a ticket" unless
          ChangeRequests.const_defined?(constant, false)

        expect(ChangeRequests.const_get(constant, false).table_name).to eq(table_name)
      end
    end

    it "derives a name from the prefix with no configuration at all" do
      model = Class.new(described_class) { def self.name = "ChangeRequests::Stage" }

      expect(model.table_name).to eq("change_request_stages")
    end

    # The one name the convention gets wrong, and the reason Request is allowed its exception.
    it "would derive change_request_requests for Request, which is why Request sets its own" do
      model = Class.new(described_class) { def self.name = "ChangeRequests::Request" }

      expect(model.table_name).to eq("change_request_requests")
    end
  end

  describe "explicit table names" do
    # A model whose table name differs from the one §4's convention would derive has opted out of
    # that convention, and only Request may. Vacuous until M1a-3 defines the first model, then true
    # of every model that exists - which is the point of deriving the list rather than writing it.
    it "is opted out of by Request and by nothing else" do
      opted_out = loaded_models.reject { |model| model.table_name == derived_table_name_for(model) }

      expect(opted_out.map(&:name)).to all(eq("ChangeRequests::Request"))
    end

    def loaded_models
      self.class.nine_tables.keys
          .select { |constant| ChangeRequests.const_defined?(constant, false) }
          .map { |constant| ChangeRequests.const_get(constant, false) }
    end

    # What Rails would produce unaided: the prefix, plus the demodulised name, pluralised.
    def derived_table_name_for(model)
      "#{ChangeRequests.table_name_prefix}#{model.name.demodulize.underscore.pluralize}"
    end
  end
end
