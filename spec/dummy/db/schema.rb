# frozen_string_literal: true

# The host application's own tables. The gem's nine tables are not here - they arrive with M1a, from
# the install generator's migration template, which is the artefact a real host would run.
#
# Three primary key types in one schema is the whole point (§15.1): it is what makes the polymorphic
# string `*_id` columns in §5.7 testable rather than merely asserted.
ActiveRecord::Schema[8.1].define(version: 0) do
  enable_extension "pgcrypto"

  create_table :users, id: :uuid, force: :cascade do |t|
    t.string :name, null: false
    t.string :email, null: false
    t.string :roles, array: true, null: false, default: []
    t.timestamps
  end

  create_table :admins, force: :cascade do |t|
    t.string :name, null: false
    t.string :roles, array: true, null: false, default: []
    t.timestamps
  end

  create_table :managers, id: :string, force: :cascade do |t|
    t.string :name, null: false
    t.string :roles, array: true, null: false, default: []
    t.timestamps
  end

  create_table :organizations, id: :uuid, force: :cascade do |t|
    t.string :name, null: false
    t.timestamps
  end
end
