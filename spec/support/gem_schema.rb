# frozen_string_literal: true

require "erb"
require "tmpdir"

# Renders the install generator's migration template into a tmpdir and runs it through
# MigrationContext - the same path as `rails db:migrate` - so the suite exercises the artefact a
# host runs.
#
# reset! migrates down and back up every run: a recorded schema_migrations row would otherwise mean
# an edited template silently did not take effect.
module GemSchema
  TEMPLATE = "lib/generators/change_requests/install/templates/migration.rb.tt"
  VERSION = "20260101000000"
  FIRST_TABLE = "change_requests"

  module_function

  def reset!
    rollback!
    migrate!
  end

  def migrate!
    context.migrate
  end

  def rollback!
    context.migrate(0)
  end

  def context
    ActiveRecord::MigrationContext.new(migration_path)
  end

  def tables
    ActiveRecord::Base.connection.tables.grep(/\Achange_request/).sort
  end

  def loaded?
    ActiveRecord::Base.connection.table_exists?(FIRST_TABLE)
  end

  # Filename must look like a generated migration for MigrationContext to see it.
  def migration_path
    @migration_path ||= Dir.mktmpdir("change_requests_migration").tap do |dir|
      File.write(File.join(dir, "#{VERSION}_create_change_requests.rb"), rendered)
    end
  end

  def rendered
    ERB.new(File.read(TEMPLATE), trim_mode: "-")
       .result_with_hash(migration_version: ActiveRecord::Migration.current_version)
  end
end
