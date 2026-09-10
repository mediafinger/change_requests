# frozen_string_literal: true

module ChangeRequests
  # Base for the nine tables. Inherits ActiveRecord::Base, not a host's ApplicationRecord, which may
  # carry anything and is undefined headless.
  #
  # Table names derive from ChangeRequests.table_name_prefix. A model setting self.table_name is
  # either Request or a mistake - record_spec asserts it.
  class Record < ::ActiveRecord::Base
    self.abstract_class = true

    # `belongs_to` reads this when the association is *declared*, and these models are loaded by
    # Zeitwerk before Rails sets it on ActiveRecord::Base - so without this every belongs_to here is
    # optional, whatever the host configured. Set on the base class, which loads first.
    self.belongs_to_required_by_default = true
  end
end
