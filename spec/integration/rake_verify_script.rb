# frozen_string_literal: true

# Runs `change_requests:verify` the way a host does - through the dummy application's environment
# and `Rails.application.load_tasks`, so the engine's lib/tasks path is what supplies the task.
# ARGV[0] picks which registry it runs against; the exit status is the assertion.
ENV["RAILS_ENV"] ||= "test"

require_relative "../dummy/config/environment"

# A target meeting §6.12's contract: a public singleton method taking keyword arguments only.
module VerifyProbe
  def self.call(**)
    :done
  end
end

case ARGV.first
when "sound"
  ChangeRequests.operations.define("orders.pay") do |op|
    op.version = "2026-09-12"
    op.service = "VerifyProbe"
    op.workflow { |w| w.stage :approval, permissions: %w(owner), threshold: 2 }
  end
when "unsound"
  ChangeRequests.operations.define("orders.pay") do |op|
    op.version = "2026-09-12"
    op.service = "Orders::NoSuchThing"
    op.workflow { |w| w.stage :approval, permissions: %w(owner), threshold: 2 }
  end
end

Rails.application.load_tasks

Rake::Task["change_requests:verify"].invoke
