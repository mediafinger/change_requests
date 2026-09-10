# frozen_string_literal: true

# A throwaway table for specs that need a real ActiveRecord model before the gem has any.
#
# The concerns in `lib/change_requests/models/concerns/` are shared behaviour, and testing them
# through whichever model happens to include them first would tie their specs to that model's
# columns and lifecycle. M1a-3 onwards test the models; this tests the behaviour they will share.
#
# Created at spec-file load rather than in a hook, so it exists outside the per-example transaction
# that `use_transactional_fixtures` opens and rolls back. `force: :cascade` makes it idempotent.
module ProbeTable
  module_function

  def create!(name)
    ActiveRecord::Base.connection.create_table(name, id: :uuid, force: :cascade) do |t|
      t.string :status
      t.string :operation_key
      t.string :label
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end
  end
end
