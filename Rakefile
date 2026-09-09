# frozen_string_literal: true

require "bundler/audit/task"
require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

# setup task bundle:audit
Bundler::Audit::Task.new

RSpec::Core::RakeTask.new(:rspec)

RuboCop::RakeTask.new

desc "Open a console with ChangeRequests loaded"
task :console do
  sh "bin/console"
end

desc "Run rubocop and the specs and check for known CVEs"
task ci: %i(rubocop rspec bundle:audit)

task default: :ci
