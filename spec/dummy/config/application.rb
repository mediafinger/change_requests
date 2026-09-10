# frozen_string_literal: true

require "active_record/railtie"

# ActionController, ActionView and ActionMailer are deliberately absent: nothing in Milestone 1
# renders anything. M6 adds what the UI needs, and until then the dummy app proves the domain core
# works inside a real Rails application with only ActiveRecord loaded.
require "change_requests"

# A normal Rails host never writes this line: `config/application.rb` loads Rails before
# `Bundler.require` reaches the gem, so requiring it loads the engine on its own.
#
# This application is not a normal host. `spec_helper` requires the gem first, before anything has
# loaded Rails, and `require` only decides once - so without this the dummy app boots with no engine
# at all, and `isolate_namespace`, the boot-time `validate!` and the route set are all inert.
ChangeRequests.load_engine!

module Dummy
  # The host application the gem's specs run against (§15.1).
  #
  # It exists to be a *realistic* host rather than a convenient one: three actor classes with three
  # different primary key types, plus a tenant. That is the configuration §5.7 designed the string
  # `*_id` columns for, and it is untestable with a single tidy `User`.
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

  config.tenant_type "Organization" do |type|
    type.key_type = :uuid
    type.label    = ->(organization) { organization.name }
  end
end
