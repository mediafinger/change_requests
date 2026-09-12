# frozen_string_literal: true

require "rails/engine"

module ChangeRequests
  # The only file in the gem that touches Rails. Zeitwerk ignores it; the entrypoint requires it via
  # load_engine! when Rails::Engine is defined.
  class Engine < ::Rails::Engine
    # Also installs table_name_prefix "change_requests_" unless the module already answers to one.
    # The entrypoint defines ours first - see ChangeRequests.table_name_prefix.
    isolate_namespace ChangeRequests

    # For generators invoked inside the engine. Host-facing generators are M7.
    config.generators do |g|
      g.test_framework :rspec
    end

    # Fail the boot, not the first request that touches the gem.
    config.after_initialize do
      ChangeRequests.config.validate!
    end

    # §6.12 point 6, in development and test only: an operation broken by an edit fails the next
    # request rather than the next deploy. Production runs `rake change_requests:verify` instead,
    # because verify! constantizes every declared service and a booted app should not pay for that
    # on every request cycle.
    #
    # Registered here rather than in the domain core, and it re-reads the registry on every run -
    # a reload redefines the classes verify! resolved last time, so nothing may be held across one.
    config.to_prepare do
      ChangeRequests.operations.verify! if Rails.env.local?
    end
  end
end
