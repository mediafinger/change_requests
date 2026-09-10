# frozen_string_literal: true

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"

require_relative "dummy/config/environment"
require "rspec/rails"

# Here rather than in a rake task, so a fresh checkout needs no remembered command. CI still runs
# `rake dummy:db:prepare` first, so a broken schema fails its own step.
DummyDatabase.prepare!

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
end
