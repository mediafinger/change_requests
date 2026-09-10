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

# §15.5's runtime half: the domain core loads, connects and runs with Rails never required. Its
# static half - that no domain file references a Rails constant - is `rake archspec` below.
#
# Run on its own in CI as well as inside the full suite, because running it alone is a stronger
# claim: the parent process never loads Rails either, so nothing can pass for the wrong reason.
RSpec::Core::RakeTask.new(:headless) do |task|
  task.pattern = "spec/integration/headless_spec.rb"
end

# §15.4. Needs no database and no dummy application - it reads the gemspec.
RSpec::Core::RakeTask.new(:packaging) do |task|
  task.pattern = "spec/integration/packaging_spec.rb,spec/gemspec_spec.rb"
end

RuboCop::RakeTask.new

# The architecture in PLAN.md §1 and §2, checked statically - see Archspec.rb for the rules. This
# is §15.5's static half, and it checks rather more besides: layer boundaries, and every directory
# M6 and M7 add. It parses rather than boots, so it needs no database and no dummy application.
desc "Check the architecture boundaries in Archspec.rb"
task :archspec do
  sh "archspec", "check"
end

# Brakeman expects a Rails application, and this is a gem: the code lives in lib/, not app/, and
# there is nothing to scan at the root until M6 adds app/controllers and app/views. `--force` is
# what makes it scan anyway, and it does reach lib/ - a planted `eval` in the domain core is
# reported, which is the point, because §6.12's dispatch resolves a class name and calls a method on
# it. That is precisely the shape Brakeman's UnsafeReflection and Send checks exist for, and M2 and
# M3 are where it lands.
#
# Scanning spec/dummy instead was the obvious alternative and is worth less: it sees the dummy's own
# four fixture models and none of the gem, because the gem is outside that directory. The gem root
# is the target that grows - at M6 the same scan picks up the engine's controllers and views, where
# XSS and redirect checks actually matter.
#
# Brakeman exits 3 when it finds a warning and 0 when it does not, so `sh` fails the build on its
# own; the two --exit-on flags say so out loud rather than relying on that.
desc "Scan for security warnings with Brakeman"
task :brakeman do
  sh "brakeman", "--force", "--no-progress", "--quiet", "--exit-on-error", "--exit-on-warn", "."
end

desc "Open a console with ChangeRequests loaded"
task :console do
  sh "bin/console"
end

desc "Run rubocop, the architecture and security checks, and the specs, and check for known CVEs"
task ci: %i(rubocop archspec brakeman rspec bundle:audit)

task default: :ci
