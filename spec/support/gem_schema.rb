# frozen_string_literal: true

require "erb"
require "tmpdir"

# Runs the install generator's migration template against the dummy database.
#
# The template is the artefact a host actually runs, so the suite runs *it* rather than a schema.rb
# copied from it. M7 writes the generator that copies it into a host's `db/migrate`; until then this
# renders it into a throwaway directory and drives it through the ordinary `MigrationContext`, which
# is the same code path `rails db:migrate` uses (risk **R2**).
#
# `reset!` migrates down and back up on every run, deliberately. A recorded schema_migrations row
# would otherwise mean an edited template silently did not take effect - the one failure mode that
# would waste an afternoon.
module GemSchema
  TEMPLATE = "lib/generators/change_requests/install/templates/migration.rb.tt"
  VERSION = "20260101000000"
  FIRST_TABLE = "change_requests"

  module_function

  def reset!
    rollback!
    migrate!
  end

  def migrate! = context.migrate

  # To zero: every table this migration created, and the schema_migrations row that remembers it.
  def rollback! = context.migrate(0)

  def context = ActiveRecord::MigrationContext.new(migration_path)

  def tables
    ActiveRecord::Base.connection.tables.grep(/\Achange_request/).sort
  end

  def loaded?
    ActiveRecord::Base.connection.table_exists?(FIRST_TABLE)
  end

  # Rendered once per process into a temporary directory, named the way a generated migration is so
  # `MigrationContext` recognises it.
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
