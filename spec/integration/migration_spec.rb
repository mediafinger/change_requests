# frozen_string_literal: true

require "rails_helper"

# The install generator's migration is the artefact a host runs, so it is driven the way a host runs
# it - through `MigrationContext`, the same code path as `rails db:migrate` - rather than by loading
# a schema.rb copied out of it (risk **R2**).
#
# Each example migrates inside the per-example transaction that `use_transactional_fixtures` opens,
# and PostgreSQL rolls DDL back like anything else. So dropping every table here cannot strand the
# specs that run after it, whatever order they run in.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "the install migration" do
  it "has created the nine tables the suite runs against" do
    expect(GemSchema).to be_loaded
  end

  describe "rolling back to zero" do
    it "leaves no table behind" do
      GemSchema.rollback!

      expect(GemSchema.tables).to be_empty
    end

    it "leaves the host's own tables alone, since it never created them" do
      GemSchema.rollback!

      expect(ActiveRecord::Base.connection.tables).to include("users", "admins", "organizations")
    end

    it "can be migrated straight back up, which is what makes it a migration and not a script" do
      GemSchema.rollback!
      GemSchema.migrate!

      expect(GemSchema.tables.size).to eq(9)
    end
  end

  describe "the template itself" do
    subject(:template) { File.read(GemSchema::TEMPLATE) }

    it "is the file the install generator will copy, not a spec fixture" do
      expect(GemSchema::TEMPLATE).to start_with("lib/generators/change_requests/install/templates/")
    end

    # M7 copies it into a host's db/migrate, where it has to name the host's Rails version.
    it "takes its migration version from the host rather than hard-coding one" do
      expect(template).to include("ActiveRecord::Migration[<%= migration_version %>]")
    end

    it "renders to something Ruby can parse" do
      expect { RubyVM::AbstractSyntaxTree.parse(GemSchema.rendered) }.not_to raise_error
    end

    # §19.11: no install-time switch, no bigint branch, no flag to get wrong.
    it "offers no primary key choice to get wrong" do
      expect(template).not_to include("primary_key_type")
    end
  end
end
