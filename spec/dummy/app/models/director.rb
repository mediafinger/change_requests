# frozen_string_literal: true

# A fourth actor class, with the same bigint key as Admin: §6.9's documented workflows gate a stage
# on an actor class rather than a permission, and that needs a class the gem has never heard of.
class Director < ApplicationRecord
end
