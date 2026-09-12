# frozen_string_literal: true

# Host tables only. The gem's nine come from the install generator's template - see GemSchema.
# Three primary key types in one schema is the point; Director shares Admin's to stay a fourth
# actor class rather than a fourth key type.
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

  create_table :directors, force: :cascade do |t|
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
