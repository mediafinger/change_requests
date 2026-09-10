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

RSpec::Core::RakeTask.new(:rspec)

RuboCop::RakeTask.new

desc "Open a console with ChangeRequests loaded"
task :console do
  sh "bin/console"
end

desc "Run rubocop and the specs and check for known CVEs"
task ci: %i(rubocop rspec bundle:audit)

task default: :ci
