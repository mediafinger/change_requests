# frozen_string_literal: true

# Throwaway table for the concern specs, so shared behaviour is not tested through whichever model
# happens to include it first.
#
# Call at spec-file load, not in a hook: it must run outside the per-example transaction that
# use_transactional_fixtures rolls back.
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
