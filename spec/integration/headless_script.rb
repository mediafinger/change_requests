# frozen_string_literal: true

# Run in a subprocess with Rails never required (§15.5). If this ever needs Rails, the seam in §1 is
# broken. M1b-14 extends it to approve a request.
#
# It builds its own database rather than borrowing the suite's: nothing here runs in a transaction,
# so committed rows would leak into every spec that counts them. A separate database also makes the
# claim stronger - this is a host installing the gem from nothing, with no Rails anywhere.

require "active_record"
require "change_requests"

require_relative "../support/gem_schema"

DATABASE = "change_requests_headless_test"

CONNECTION = {
  adapter: "postgresql",
  host: ENV.fetch("PGHOST", "localhost"),
  username: ENV.fetch("PGUSER", ENV.fetch("USER", "postgres")),
  password: ENV.fetch("PGPASSWORD", nil),
}.freeze

def report(key, value)
  puts("#{key}=#{value}")
end

# Everything below is worthless if something dragged Rails in, so say so first and loudly.
report :rails, defined?(Rails) ? "loaded" : "absent"
report :action_controller, defined?(ActionController) ? "loaded" : "absent"
report :engine, defined?(ChangeRequests::Engine) ? "defined" : "absent"

# A misfiled constant should fail here, not in a host application.
ChangeRequests.loader.eager_load
report :eager_load, "ok"

report :table_name_prefix, ChangeRequests.table_name_prefix
report :system_actor, ChangeRequests::SYSTEM_ACTOR.fetch(:id)

# An actor is any object whose class is registered. No ActiveRecord, no host framework.
HeadlessActor = Struct.new(:id, :name, :roles)

ChangeRequests.configure do |config|
  config.actor_type "HeadlessActor" do |type|
    type.key_type = :string
    type.label = ->(actor) { actor.name }
    type.permissions = ->(actor) { actor.roles }
  end
end
report :validate, ChangeRequests.config.validate!

# The error taxonomy produces a message with no I18n and no locale files.
report :error_message, ChangeRequests::NotApprovable.new(reason: :requester).message

# A bare ActiveRecord connection - no database.yml, no Rails.application, no railtie.
ActiveRecord::Base.establish_connection(**CONNECTION, database: "postgres")
ActiveRecord::Base.connection.drop_database(DATABASE)
ActiveRecord::Base.connection.create_database(DATABASE)
ActiveRecord::Base.establish_connection(**CONNECTION, database: DATABASE)

report :adapter, ActiveRecord::Base.connection.adapter_name

# The child inherits the bundle through RUBYOPT, which is what keeps json pinned to 2.x. Reported so
# a jsonb failure below names its cause instead of surfacing as an ArgumentError from JSON.parse.
report :json, JSON::VERSION

# The install generator's migration, run the way a host runs it.
GemSchema.migrate!
report :tables, GemSchema.tables.size

requester = HeadlessActor.new("act-1", "Ada Lovelace", %w(owner))

request = ChangeRequests::Request.create!(
  operation_key: "members.update_roles",
  service: "Members::UpdateRoles",
  method_name: "call",
  operation_version: "2026-09-11",
  requester: requester,
  payload: { "member_id" => 7, "roles" => %w(editor) }
)

report :request, request.status
report :requester_label, request.requester_label
report :payload_roundtrip, request.reload.payload.fetch("roles").first

stage = request.stages.create!(position: 1, name: "operational")
quorum = stage.quorums.create!(position: 1, threshold: 2, name: "owners")
quorum.permissions.create!(permission: "owner")

report :stage_label, stage.label
report :quorum_threshold, quorum.threshold

request.events.create!(
  **ChangeRequests::Event::SYSTEM_ATTRIBUTES,
  kind: "requested", operation_version: request.operation_version, occurred_at: Time.now
)

report :events, request.reload.events.count
report :event_actor, request.events.first.actor_label

# The guards refuse a terminal request even with no command layer loaded.
request.update!(status: "canceled")

begin
  request.update!(status: "pending")
  report :terminal_guard, "NOT ENFORCED"
rescue ChangeRequests::AlreadyFinalized
  report :terminal_guard, "enforced"
end

ActiveRecord::Base.establish_connection(**CONNECTION, database: "postgres")
ActiveRecord::Base.connection.drop_database(DATABASE)
report :cleanup, "ok"

# Re-checked at the end: something loaded along the way could have pulled Rails in behind us.
report :rails_at_exit, defined?(Rails) ? "loaded" : "absent"
