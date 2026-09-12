# frozen_string_literal: true

# Runs one maintenance task the way a host's cron does - through the dummy application's
# environment and `Rails.application.load_tasks`, so the engine's lib/tasks path supplies it.
#
# Everything happens inside a transaction that is rolled back: this writes to the same database
# the suite uses, and a committed row here would surface in whichever spec counted next.
ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

module MaintenanceProbe
  def self.call(**)
    :done
  end
end

def declare!
  ChangeRequests.operations.define("maintenance.probe") do |op|
    op.version = "2026-09-12"
    op.service = "MaintenanceProbe"
    op.workflow { |w| w.stage :approval, permissions: %w(member_admin), threshold: 1 }
  end
end

def create!
  ChangeRequests::Commands::Create.call(
    operation_key: "maintenance.probe",
    requester: User.create!(name: "Ada", email: "ada-#{SecureRandom.hex(4)}@example.com")
  )
end

def seed!(task_name)
  case task_name
  when "expire_stale"
    create!.update_columns(expires_at: 1.minute.ago)
  when "reap_stuck_executions"
    request = create!
    request.update_columns(status: "executing")
    request.attempts.create!(number: 1, started_at: 2.hours.ago,
                             executer_type: "User", executer_id: "1", executer_label: "Ada")
  when "cancel_undeclared"
    create!
    ChangeRequests.operations.clear
  end
end

declare!
Rails.application.load_tasks

ActiveRecord::Base.transaction do
  # ARGV[1] == "empty" runs the task against nothing, which is the ordinary case on a quiet hour.
  seed!(ARGV.first) unless ARGV[1] == "empty"

  Rake::Task["change_requests:#{ARGV.first}"].invoke

  fail ActiveRecord::Rollback
end
