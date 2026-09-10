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
# Run as its own task in CI as well as inside the full suite, because running it alone is a stronger
# claim: `RSpec::Core::RakeTask` shells out to a fresh `ruby … rspec`, so the parent process never
# loads Rails either and nothing can pass for the wrong reason. The isolation is the separate
# *process*, not a separate CI job - which is why CI can group it with the rest of the specs.
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
# there is nothing at the root to recognise until M6 adds app/controllers and app/views.
# `--force-scan` is what makes it scan anyway - without it, it refuses *and exits 0*, which is the
# worst of both worlds.
#
# It does reach lib/: a planted `eval` in the domain core is reported. That is the point, because
# §6.12's dispatch resolves a stored class name and calls a method on it, which is precisely the
# shape UnsafeReflection and Send exist for. M2 and M3 are where that lands.
#
# Two things were measured rather than assumed, so they do not have to be re-litigated:
#
#   * `--add-engines-path .` and `--add-libs-path lib` add nothing here. They exist for engines and
#     Ruby that live *outside* the scanned root; the gem root already is the root, and Brakeman
#     scans app/, lib/ and config/ under it by default. Checked against a simulated M6 tree - a
#     vulnerable controller and view under app/ - where plain `--force-scan` found all five
#     warnings (CSRF, XSS, redirect, SQL injection, eval) and the extra flags changed nothing.
#   * Scanning spec/dummy instead is worth less: it needs no --force-scan but reports the dummy's
#     own four fixture models and none of the gem, which sits outside that directory. The gem root
#     is also the target that grows into M6's controllers and views.
#
# Brakeman exits 3 when it finds a warning and 0 when it does not, so `sh` fails the build on its
# own; the two --exit-on flags say so out loud rather than relying on that.
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
