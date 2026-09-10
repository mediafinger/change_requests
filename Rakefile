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

# §15.5's runtime half; the static half is `rake archspec`. Kept a separate task because
# RSpec::Core::RakeTask shells out to a fresh process, so the parent never loads Rails either. The
# isolation is the process, not a CI job - which is why CI can group it with the other specs.
RSpec::Core::RakeTask.new(:headless) do |task|
  task.pattern = "spec/integration/headless_spec.rb"
end

# §15.4. Needs no database and no dummy application - it reads the gemspec.
RSpec::Core::RakeTask.new(:packaging) do |task|
  task.pattern = "spec/integration/packaging_spec.rb,spec/gemspec_spec.rb"
end

RuboCop::RakeTask.new

# §15.5's static half, plus layer boundaries. Rules in Archspec.rb. Parses; needs no database.
desc "Check the architecture boundaries in Archspec.rb"
task :archspec do
  sh "archspec", "check"
end

# --force-scan because this is a gem, not an app: without it Brakeman refuses *and exits 0*. It does
# reach lib/, which is what matters - §6.12's dispatch constantizes a stored string and calls a
# method on it, the shape UnsafeReflection and Send exist for.
#
# Measured, so it need not be re-argued: --add-engines-path and --add-libs-path change nothing (the
# gem root already is the scanned root), and scanning spec/dummy instead sees only the dummy's own
# fixture models. Brakeman exits 3 on a warning; the --exit-on flags make that explicit.
desc "Scan for security warnings with Brakeman"
task :brakeman do
  sh "brakeman", "--force-scan", "--no-progress", "--no-summary", "--quiet", "--exit-on-error", "--exit-on-warn"
end

desc "Open a console with ChangeRequests loaded"
task :console do
  sh "bin/console"
end

desc "Run rubocop, the architecture and security checks, and the specs, and check for known CVEs"
task ci: %i(rubocop archspec brakeman rspec bundle:audit)

task default: :ci
