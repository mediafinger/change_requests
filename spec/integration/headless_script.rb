# frozen_string_literal: true

# Run in a subprocess with Rails never required (§15.5). If this ever needs Rails, the seam in §1 is
# broken. M1a-10 extends it to migrate and create a request; M1b-14 to approve one.

require "active_record"
require "change_requests"

def report(key, value) = puts("#{key}=#{value}")

# Everything below is worthless if something dragged Rails in, so say so first and loudly.
report :rails, defined?(Rails) ? "loaded" : "absent"
report :action_controller, defined?(ActionController) ? "loaded" : "absent"
report :engine, defined?(ChangeRequests::Engine) ? "defined" : "absent"

# A misfiled constant should fail here, not in a host application.
ChangeRequests.loader.eager_load
report :eager_load, "ok"

report :table_name_prefix, ChangeRequests.table_name_prefix
report :system_actor, ChangeRequests::SYSTEM_ACTOR.fetch(:id)

# Configuration and its validation are domain concerns, not Rails ones.
ChangeRequests.configure do |config|
  config.actor_type "User" do |type|
    type.key_type    = :uuid
    type.label       = ->(user) { user.name }
    type.permissions = ->(user) { user.roles }
  end
end
report :validate, ChangeRequests.config.validate!

# The error taxonomy produces a message with no I18n and no locale files.
report :error_message, ChangeRequests::NotApprovable.new(reason: :requester).message

# A bare ActiveRecord connection - no database.yml, no Rails.application, no railtie.
ActiveRecord::Base.establish_connection(
  adapter:  "postgresql",
  host:     ENV.fetch("PGHOST", "localhost"),
  username: ENV.fetch("PGUSER", ENV.fetch("USER", "postgres")),
  password: ENV.fetch("PGPASSWORD", nil),
  database: ENV.fetch("CHANGE_REQUESTS_TEST_DATABASE", "change_requests_test")
)

report :adapter, ActiveRecord::Base.connection.adapter_name
report :query, ActiveRecord::Base.connection.select_value("SELECT 1")

# Re-checked at the end: something loaded along the way could have pulled Rails in behind us.
report :rails_at_exit, defined?(Rails) ? "loaded" : "absent"
