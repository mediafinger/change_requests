# frozen_string_literal: true

# Creates the dummy app's database if it is missing and loads its schema.
#
# Deliberately not a `db:test:prepare` the developer has to remember: a first `bundle exec rspec` on
# a fresh checkout should work, and a schema change should take effect without a second command.
# Loading is cheap - four small tables - and `force: :cascade` makes it idempotent.
#
# Defined in spec/support so it never ships inside the gem; the gem has no opinion about how a host
# creates its own database.
module DummyDatabase
  module_function

  def prepare!
    create_unless_exists

    ActiveRecord::Base.establish_connection(db_config)
    load_schema
  end

  def db_config
    ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: "primary")
  end

  def create_unless_exists
    ActiveRecord::Tasks::DatabaseTasks.create(db_config)
  rescue ActiveRecord::DatabaseAlreadyExists
    nil
  end

  def load_schema
    was_verbose = ActiveRecord::Schema.verbose
    ActiveRecord::Schema.verbose = false

    load Rails.root.join("db/schema.rb")
  ensure
    ActiveRecord::Schema.verbose = was_verbose
  end
end
