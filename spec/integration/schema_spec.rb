# frozen_string_literal: true

require "rails_helper"

# Asserted against pg_index and pg_constraint, not the migration file, which would only prove the
# file says what it says. After the first adopter every schema change is a migration in their repo.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "the generated schema" do
  def self.nine_tables
    %w(
      change_requests
      change_request_stages
      change_request_quorums
      change_request_quorum_permissions
      change_request_quorum_eligible_actors
      change_request_approvals
      change_request_approval_quorums
      change_request_events
      change_request_attempts
    ).freeze
  end

  let(:connection) { ActiveRecord::Base.connection }

  describe "the tables" do
    it "creates all nine of §4's tables and no others" do
      expect(GemSchema.tables).to match_array(self.class.nine_tables)
    end
  end

  # §5.7, §19.11: every gem-owned key is a uuid. A hand-edited migration that reintroduced a bigint
  # somewhere would still work until the first join, and then not.
  describe "key types" do
    nine_tables.each do |table|
      it "gives #{table} a uuid primary key" do
        expect(column_type(table, "id")).to eq("uuid")
      end
    end

    it "makes every foreign key between these tables a uuid" do
      internal_keys = self.class.nine_tables.flat_map do |table|
        connection.columns(table)
                  .map(&:name)
                  .grep(/\Achange_request(_stage|_quorum|_approval)?_id\z/)
                  .map { |column| ["#{table}.#{column}", column_type(table, column)] }
      end

      expect(internal_keys.map(&:last).uniq).to eq(["uuid"])
    end

    # The one place a key is deliberately not a uuid: a `User` with a uuid key and an `Admin` with a
    # bigint key have to share one column, so it is text (§5.7 consequence 1).
    it "keeps the polymorphic references to host records a string" do
      host_references = [
        %w(change_requests requester_id),
        %w(change_requests executer_id),
        %w(change_requests tenant_id),
        %w(change_request_approvals approver_id),
        %w(change_request_events actor_id),
        %w(change_request_attempts executer_id),
        %w(change_request_quorum_eligible_actors actor_id),
      ]

      types = host_references.map { |table, column| column_type(table, column) }

      expect(types.uniq).to eq(["character varying"])
    end
  end

  describe "foreign keys" do
    it "cascades every one of them, so deleting a request takes its whole graph" do
      actions = self.class.nine_tables.flat_map { |table| connection.foreign_keys(table) }
                    .map { |key| key.options[:on_delete] }

      expect(actions.uniq).to eq([:cascade])
    end

    # §5.7 consequence 2: nothing points at a host table, ever.
    it "points at nothing outside these nine tables" do
      targets = self.class.nine_tables.flat_map { |table| connection.foreign_keys(table) }
                    .map(&:to_table)

      expect(targets.uniq - self.class.nine_tables).to be_empty
    end
  end

  describe "indexes" do
    {
      "change_requests" => [%w(status), %w(operation_key), %w(requester_type requester_id),
                            %w(executer_type executer_id)],
      "change_request_stages" => [%w(change_request_id)],
      "change_request_quorums" => [%w(change_request_stage_id)],
      "change_request_quorum_permissions" => [%w(permission)],
      "change_request_quorum_eligible_actors" => [%w(actor_type actor_id)],
      "change_request_events" => [%w(change_request_id occurred_at)],
      "change_request_attempts" => [%w(change_request_id number)],
    }.each do |table, column_sets|
      column_sets.each do |columns|
        it "indexes #{table} on #{columns.join(", ")}" do
          expect(indexed_column_sets(table)).to include(columns)
        end
      end
    end

    it "enforces one decision per approver per stage in the database, not in Ruby (§5.4)" do
      expect(unique_index_columns("change_request_approvals"))
        .to include(%w(change_request_stage_id approver_type approver_id))
    end

    it "enforces one stage position and one stage name per request" do
      expect(unique_index_columns("change_request_stages"))
        .to include(%w(change_request_id position), %w(change_request_id name))
    end

    it "enforces one attempt number per request, which is the claim's second lock (§8)" do
      expect(unique_index_columns("change_request_attempts")).to include(%w(change_request_id number))
    end

    describe "the partial ones" do
      it "narrows the expiry index to requests still in flight" do
        expect(index_predicate("index_change_requests_on_expires_at_when_open"))
          .to include("pending", "approved")
      end

      it "narrows the override index to requests that were overridden" do
        expect(index_predicate("index_change_requests_on_overridden_at_when_set"))
          .to include("overridden_at IS NOT NULL")
      end

      # A quorum's name is null when its stage holds only one, and several such rows must coexist.
      it "narrows the quorum name index to named quorums" do
        expect(index_predicate("index_change_request_quorums_on_stage_and_name"))
          .to include("name IS NOT NULL")
      end
    end

    # Issue I3. Both columns are nullable and PostgreSQL treats every NULL as distinct by default, so
    # without this the "any permission / any actor type" row could be inserted twice.
    describe "the quorum permissions unique index" do
      it "exists" do
        expect(unique_index_columns("change_request_quorum_permissions"))
          .to include(%w(change_request_quorum_id permission actor_type))
      end

      it "is NULLS NOT DISTINCT" do
        expect(nulls_not_distinct?("index_change_request_quorum_permissions_unique")).to be(true)
      end

      it "actually refuses the duplicate, which is the only proof that matters" do
        quorum_id = create_quorum

        insert_permission(quorum_id, permission: nil, actor_type: "Admin")

        expect { insert_permission(quorum_id, permission: nil, actor_type: "Admin") }
          .to raise_error(ActiveRecord::RecordNotUnique)
      end
    end
  end

  # Each one proven by an INSERT that violates it - a constraint that exists but does not bite is a
  # comment with extra steps.
  describe "check constraints" do
    it "refuses a status outside §5.8's eight" do
      expect { insert_request(status: "nearly") }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "accepts each of the eight" do
      %w(pending approved executing successful failed rejected canceled expired).each do |status|
        expect { insert_request(status: status) }.not_to raise_error
      end
    end

    it "refuses max_attempts below one, since one attempt is the default and not zero" do
      expect { insert_request(max_attempts: 0) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "refuses a stage position below one" do
      expect { insert_stage(position: 0) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "refuses an unknown satisfied_by" do
      expect { insert_stage(satisfied_by: "either_quorum") }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "refuses a quorum threshold below one" do
      expect { insert_quorum_row(threshold: 0) }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "refuses an unknown permission_match" do
      expect { insert_quorum_row(permission_match: "some") }.to raise_error(ActiveRecord::StatementInvalid)
    end

    # A row that constrains nothing is a bug, not a wildcard (§5.3).
    it "refuses a permission row that constrains neither permission nor actor type" do
      expect { insert_permission(create_quorum, permission: nil, actor_type: nil) }
        .to raise_error(ActiveRecord::StatementInvalid)
    end

    it "accepts a permission row that constrains either one" do
      quorum_id = create_quorum

      expect { insert_permission(quorum_id, permission: "owner", actor_type: nil) }.not_to raise_error
      expect { insert_permission(quorum_id, permission: nil, actor_type: "Admin") }.not_to raise_error
    end

    it "refuses an unknown attempt outcome" do
      expect { insert_attempt(create_request, outcome: "nearly") }
        .to raise_error(ActiveRecord::StatementInvalid)
    end

    # Null while the attempt is still in flight, which is most of its life.
    it "allows no outcome at all" do
      expect { insert_attempt(create_request, outcome: nil) }.not_to raise_error
    end

    # §19.16: every later milestone adds kinds, and a CHECK would make each one a host migration.
    it "does not constrain the event kind, which an inclusion validation carries instead" do
      names = connection.check_constraints("change_request_events").map(&:name)

      expect(names).to be_empty
    end
  end

  describe "column shapes" do
    it "stores payloads as jsonb, never json (§5.7)" do
      types = [
        column_type("change_requests", "payload"),
        column_type("change_requests", "payload_labels"),
        column_type("change_request_events", "metadata"),
      ]

      expect(types.uniq).to eq(["jsonb"])
    end

    it "defaults those payloads to an empty object rather than null" do
      expect(insert_request_row.fetch("payload")).to eq("{}")
    end

    it "gives events a created_at and no updated_at, because they are never updated (§5.5)" do
      names = connection.columns("change_request_events").map(&:name)

      expect(names).to include("created_at")
      expect(names).not_to include("updated_at")
    end

    it "makes the event actor triple not null, because the System sentinel fills it (§19.15)" do
      nullable = connection.columns("change_request_events")
                           .select { |c| %w(actor_type actor_id actor_label).include?(c.name) }
                           .select(&:null)

      expect(nullable).to be_empty
    end

    it "leaves the tenant triple nullable, since tenancy is optional (§5.1)" do
      nullable = connection.columns("change_requests")
                           .select { |c| %w(tenant_type tenant_id tenant_label).include?(c.name) }
                           .all?(&:null)

      expect(nullable).to be(true)
    end

    # §19.12 and §19.13: the attempts rows are the count, and the request id is the idempotency key.
    it "carries neither an attempts_count nor an idempotency_key column" do
      names = connection.columns("change_requests").map(&:name)

      expect(names).not_to include("attempts_count", "idempotency_key")
    end
  end

  # A default is a contract: the migration promises a new row starts pending, on stage one, with one
  # attempt allowed. The models rely on it rather than restating it.
  describe "column defaults" do
    {
      %w(change_requests status) => "pending",
      %w(change_requests current_stage_position) => "1",
      %w(change_requests max_attempts) => "1",
      %w(change_requests lock_version) => "0",
      %w(change_request_stages status) => "pending",
      %w(change_request_stages satisfied_by) => "any_quorum",
      %w(change_request_quorums status) => "pending",
      %w(change_request_quorums permission_match) => "any",
    }.each do |(table, column), expected|
      it "defaults #{table}.#{column} to #{expected}" do
        # to_s because integer columns report a typed default and string columns a string.
        expect(column_default(table, column).to_s).to eq(expected)
      end
    end

    it "defaults every jsonb column to an empty object rather than null" do
      defaults = [
        column_default("change_requests", "payload"),
        column_default("change_requests", "payload_labels"),
        column_default("change_request_events", "metadata"),
      ]

      expect(defaults.uniq).to eq(["{}"])
    end
  end

  # A NOT NULL the migration forgot is a column the models have to defend in Ruby forever.
  describe "nullability" do
    {
      "change_requests" => %w(operation_key operation_version service method_name status payload
                              payload_labels requester_type requester_id requester_label
                              current_stage_position max_attempts lock_version),
      "change_request_stages" => %w(change_request_id position name satisfied_by status),
      "change_request_quorums" => %w(change_request_stage_id position threshold permission_match status),
      "change_request_quorum_eligible_actors" => %w(change_request_quorum_id actor_type actor_id),
      "change_request_approvals" => %w(change_request_id change_request_stage_id approver_type
                                       approver_id approver_label decision decided_at),
      "change_request_events" => %w(change_request_id actor_type actor_id actor_label kind
                                    operation_version metadata occurred_at created_at),
      "change_request_attempts" => %w(change_request_id number),
    }.each do |table, columns|
      it "makes #{table}'s required columns NOT NULL" do
        nullable = connection.columns(table).select { |c| columns.include?(c.name) && c.null }

        expect(nullable.map(&:name)).to be_empty
      end
    end

    it "leaves the columns that are genuinely optional nullable" do
      optional = {
        "change_requests" => %w(executer_type executer_id executer_label tenant_type tenant_id
                                tenant_label expires_at executed_at overridden_at),
        "change_request_quorums" => %w(name satisfied_at),
        "change_request_quorum_permissions" => %w(permission actor_type),
        "change_request_approvals" => %w(approver_identity comment),
        "change_request_events" => %w(body),
        "change_request_attempts" => %w(outcome error_class error_message backtrace),
      }

      not_nullable = optional.flat_map do |table, columns|
        connection.columns(table).reject(&:null).select { |c| columns.include?(c.name) }
                  .map { |c| "#{table}.#{c.name}" }
      end

      expect(not_nullable).to be_empty
    end
  end

  # Helpers. Raw SQL throughout: there are no models until M1a-3, and the point is the database.
  def column_default(table, column)
    connection.columns(table).find { |c| c.name == column }&.default
  end

  def column_type(table, column)
    connection.columns(table).find { |c| c.name == column }&.sql_type
  end

  def indexed_column_sets(table)
    connection.indexes(table).map { |index| Array(index.columns) }
  end

  def unique_index_columns(table)
    connection.indexes(table).select(&:unique).map { |index| Array(index.columns) }
  end

  def index_predicate(name)
    connection.select_value(<<~SQL.squish).to_s
      SELECT pg_get_expr(indpred, indrelid)
        FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
       WHERE pg_class.relname = #{connection.quote(name)}
    SQL
  end

  def nulls_not_distinct?(name)
    connection.select_value(<<~SQL.squish)
      SELECT indnullsnotdistinct
        FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
       WHERE pg_class.relname = #{connection.quote(name)}
    SQL
  end

  def insert_request(**overrides)
    attributes = {
      operation_key: "members.update_roles", service: "Members::UpdateRoles", method_name: "call",
      operation_version: "2026-09-10", status: "pending",
      requester_type: "User", requester_id: "1", requester_label: "Ada",
      created_at: "now()", updated_at: "now()"
    }.merge(overrides)

    insert("change_requests", attributes)
  end

  def insert_request_row
    id = create_request

    connection.select_one("SELECT * FROM change_requests WHERE id = #{connection.quote(id)}")
  end

  def create_request
    insert_request
  end

  def insert_stage(**overrides)
    attributes = {
      change_request_id: create_request, position: 1, name: "operational",
      satisfied_by: "any_quorum", status: "pending", created_at: "now()", updated_at: "now()"
    }.merge(overrides)

    insert("change_request_stages", attributes)
  end

  def create_quorum
    insert_quorum_row
  end

  def insert_quorum_row(**overrides)
    attributes = {
      change_request_stage_id: insert_stage, position: 1, threshold: 1,
      permission_match: "any", status: "pending", created_at: "now()", updated_at: "now()"
    }.merge(overrides)

    insert("change_request_quorums", attributes)
  end

  def insert_permission(quorum_id, permission:, actor_type:)
    insert("change_request_quorum_permissions",
           change_request_quorum_id: quorum_id, permission: permission, actor_type: actor_type)
  end

  def insert_attempt(request_id, outcome:)
    insert("change_request_attempts",
           change_request_id: request_id, number: rand(1..1_000_000), outcome: outcome,
           created_at: "now()", updated_at: "now()")
  end

  def insert(table, attributes)
    columns = attributes.keys.join(", ")
    values = attributes.values.map { |value| value == "now()" ? "now()" : connection.quote(value) }.join(", ")

    connection.select_value("INSERT INTO #{table} (#{columns}) VALUES (#{values}) RETURNING id")
  end
end
