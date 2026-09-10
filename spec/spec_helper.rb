# frozen_string_literal: true

require "change_requests"

# Eager load in the test environment so a constant in the wrong file, or a file in the wrong
# directory, fails the suite rather than surfacing as a NameError in a host application (§2).
ChangeRequests.loader.eager_load

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
