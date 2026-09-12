# frozen_string_literal: true

require "active_record/railtie"

# ActionController and friends deliberately absent: nothing in Milestone 1 renders. M6 adds them.
require "change_requests"

# A normal host never writes this. Here spec_helper requires the gem before Rails exists, and
# `require` only decides once - without this the app boots with no engine at all.
ChangeRequests.load_engine!

module Dummy
  # Three actor classes with three primary key types, plus a tenant: the configuration §5.7's
  # string `*_id` columns exist for, and untestable with one tidy User.
  class Application < Rails::Application
    config.load_defaults 8.1
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.secret_key_base = "dummy" * 16

    config.active_record.maintain_test_schema = false
  end
end

ChangeRequests.configure do |config|
  # uuid, bigint and string primary keys in one application - the point of the whole arrangement.
  config.actor_type "User" do |type|
    type.key_type    = :uuid
    type.label       = ->(user) { user.name }
    type.permissions = ->(user) { user.roles }
  end

  config.actor_type "Admin" do |type|
    type.key_type    = :integer
    type.label       = ->(admin) { "#{admin.name} (admin)" }
    type.permissions = ->(admin) { admin.roles + %w(admin) }
  end

  config.actor_type "Manager" do |type|
    type.key_type    = :string
    type.label       = ->(manager) { manager.name }
    type.permissions = ->(manager) { manager.roles }
  end

  # §6.9's workflows gate a stage on an actor class. Same key type as Admin deliberately - the
  # three-key-type point is made elsewhere, and this class exists to be gated on.
  config.actor_type "Director" do |type|
    type.key_type    = :integer
    type.label       = ->(director) { director.name }
    type.permissions = ->(director) { director.roles }
  end

  config.tenant_type "Organization" do |type|
    type.key_type = :uuid
    type.label    = ->(organization) { organization.name }
  end
end
