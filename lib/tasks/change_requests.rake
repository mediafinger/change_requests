# frozen_string_literal: true

# Loaded by the engine's lib/tasks path, so a host gets these from its own `Rails.application
# .load_tasks` with nothing to require. M3b adds the maintenance sweepers to this namespace.
namespace :change_requests do
  desc "Verify every declared operation: its version, target and workflow (§6.12 point 6)"
  task verify: :environment do
    count = ChangeRequests.operations.keys.size

    begin
      ChangeRequests.operations.verify!
    rescue ChangeRequests::ConfigurationError => e
      warn e.message

      # Non-zero so CI fails on it. `exit` rather than `abort`, whose message would repeat e.
      exit 1
    end

    puts "ChangeRequests: #{count} #{"operation".pluralize(count)} verified."
  end
end
