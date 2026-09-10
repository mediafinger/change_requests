# frozen_string_literal: true

# An actor with a string primary key. Unusual, and deliberately so: `*_id` is a string column, and
# this is the class that proves the resolver cannot simply cast everything to an integer or a uuid.
class Manager < ApplicationRecord
  self.primary_key = "id"
end
