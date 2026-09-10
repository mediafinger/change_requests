# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

require_relative "tasks/bundle_audit"

# setup task bundle:audit - see tasks/bundle_audit.rb for why the stock task is not used
namespace :bundle do
  namespace :audit do
    desc "Check the active gemfile's lockfile for known CVEs"
    task :check do
      sh(*BundleAudit.check_command)
    end

    desc "Update the bundler-audit vulnerability database"
    task :update do
      sh(*BundleAudit.update_command)
    end
  end

  desc "Check the active gemfile's lockfile for known CVEs"
  task audit: "audit:check"
end

namespace :dummy do
  namespace :db do
    desc "Create the dummy application's test database and load its schema"
    task :prepare do
      ENV["RAILS_ENV"] ||= "test"

      require_relative "spec/dummy/config/environment"
      require_relative "spec/support/dummy_database"

      DummyDatabase.prepare!

      puts "Prepared #{DummyDatabase.db_config.database}"
    end
  end
end

RSpec::Core::RakeTask.new(:rspec)

# §15.5, both halves: the domain core runs with Rails never required, and no file under
# lib/change_requests/ except the engine references a Rails constant.
#
# Run on their own in CI as well as inside the full suite, because running them alone is a stronger
# claim: the parent process never loads Rails either, so nothing can pass for the wrong reason.
RSpec::Core::RakeTask.new(:headless) do |task|
  task.pattern = "spec/integration/headless_spec.rb,spec/integration/domain_purity_spec.rb"
end

# §15.4. Needs no database and no dummy application - it reads the gemspec.
RSpec::Core::RakeTask.new(:packaging) do |task|
  task.pattern = "spec/integration/packaging_spec.rb,spec/gemspec_spec.rb"
end

RuboCop::RakeTask.new

# The architecture in PLAN.md §1 and §2, checked statically - see Archspec.rb for the rules. It
# parses rather than boots, so it needs no database and no dummy application.
desc "Check the architecture boundaries in Archspec.rb"
task :archspec do
  sh "archspec", "check"
end

desc "Open a console with ChangeRequests loaded"
task :console do
  sh "bin/console"
end

desc "Run rubocop, the architecture checks and the specs, and check for known CVEs"
task ci: %i(rubocop archspec rspec bundle:audit)

task default: :ci
