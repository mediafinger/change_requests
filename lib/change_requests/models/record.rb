# frozen_string_literal: true

module ChangeRequests
  # Base for the nine tables. Inherits ActiveRecord::Base, not a host's ApplicationRecord, which may
  # carry anything and is undefined headless.
  #
  # Table names derive from ChangeRequests.table_name_prefix. A model setting self.table_name is
  # either Request or a mistake - record_spec asserts it.
  class Record < ::ActiveRecord::Base
    self.abstract_class = true
  end
end
