# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "dummy/config/environment"
require "rspec/rails"

# Creating the database and loading the schema happens here rather than in a rake task the developer
# has to remember. CI still runs `rake dummy:db:prepare` first, so a broken schema fails its own
# step rather than as a confusing spec failure.
DummyDatabase.prepare!

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
end
