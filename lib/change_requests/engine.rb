# frozen_string_literal: true

require "rails/engine"

module ChangeRequests
  # The Rails integration layer, and the only file in the gem that touches Rails (§1).
  #
  # It is required from `lib/change_requests.rb` when - and only when - `Rails::Engine` is already
  # defined, and it is ignored by the Zeitwerk loader so that eager loading a headless process never
  # pulls it in. Everything under `lib/change_requests/` other than this file runs against a bare
  # ActiveRecord connection with `Rails` undefined, which `spec/integration/headless_spec.rb` proves.
  #
  # A future split into `change_requests` + `change_requests-rails` stays a `git mv` and a gemspec.
  class Engine < ::Rails::Engine
    # No constant or route leakage into the host (§1).
    #
    # This is also the reason `ChangeRequests.table_name_prefix` is defined in the entrypoint, which
    # loads first: `isolate_namespace` installs its own `table_name_prefix` - which would yield
    # `change_requests_stages` rather than §4's `change_request_stages` - only `unless
    # mod.respond_to?(:table_name_prefix)`. Ours is already there, so it wins.
    isolate_namespace ChangeRequests

    # The gem's own suite is RSpec, so generators invoked inside the engine produce RSpec files
    # rather than the Minitest default (§20.1). Host-facing generators are §13 and arrive with M7.
    config.generators do |g|
      g.test_framework :rspec
    end

    # Fail the boot, not the first request. A misconfiguration is a deploy-time problem with an
    # actionable message (§10); `validate!` names every problem at once.
    config.after_initialize do
      ChangeRequests.config.validate!
    end
  end
end
