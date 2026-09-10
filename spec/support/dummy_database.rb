# frozen_string_literal: true

require_relative "gem_schema"

# Creates the database if missing and loads the schema, so a first `rspec` on a fresh checkout
# works with no remembered command. force: :cascade makes it idempotent.
module DummyDatabase
  module_function

  def prepare!
    create_unless_exists

    ActiveRecord::Base.establish_connection(db_config)
    load_schema

    # From the install generator's template, not a schema.rb copied out of it.
    GemSchema.reset!
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
