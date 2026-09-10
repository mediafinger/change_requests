# frozen_string_literal: true

# Required here, not left to the host: eager loading must work in a process that never loads Rails.
require "active_record"
require "zeitwerk"

require_relative "change_requests/version"
require_relative "change_requests/errors"

module ChangeRequests
  # Sentinel for gem-originated events (expiry, reaper, undeclared-operation cancellation). Id is
  # "system", not "0": actor ids share a string column with host classes that may have string keys.
  SYSTEM_ACTOR = { type: "System", id: "system", label: "System" }.freeze

  class << self
    attr_reader :loader

    # Must be defined before engine.rb loads: `isolate_namespace` installs its own only
    # `unless mod.respond_to?(:table_name_prefix)`, and its version yields `change_requests_stages`.
    # `Request` is the one model that overrides its table name; it would derive
    # `change_request_requests`.
    def table_name_prefix = "change_request_"

    def config = @config ||= Configuration.new

    # The declaration registry (§6.12). Memoised for the same reason as config: initializers
    # accumulate into it.
    def operations = @operations ||= Operations.new

    # The (type, id, label) triple for a host record, with the label snapshotted through the
    # registered lambda. Raises before anything is constantized: the registry is the allowlist, and
    # `actor.class.name` is only ever compared against it (§5.7).
    def actor_attributes(actor, registry: :actor_types)
      type = actor.class.name
      registered = config.public_send(registry)[type]

      if registered.nil?
        fail UnknownActorType,
             "#{type} is not a registered #{registry.to_s.singularize.humanize.downcase}. " \
             "Register it with `config.#{registry.to_s.singularize} \"#{type}\"`."
      end

      { type: type, id: actor.id.to_s, label: registered.label.call(actor).to_s }
    end

    def configure
      yield(config)

      config
    end

    # Idempotent. Called automatically on require, which covers a normal host: application.rb loads
    # Rails before Bundler.require reaches the gem. Public because that order is not guaranteed -
    # requiring this gem before Rails skips the engine permanently, since `require` only fires once.
    # spec/dummy is such a host.
    def load_engine!
      # The only two Rails-facing references the domain is allowed. Both `defined?`-guarded, so
      # neither loads anything. Fully qualified: a host's own top-level `Engine` would match.
      # archspec:disable-next-line dependencies.forbid -- the loader must name what it loads (§1)
      return false if defined?(ChangeRequests::Engine)
      # archspec:disable-next-line constants.forbid -- the guard that makes the Rails layer opt-in (§1)
      return false unless defined?(::Rails::Engine)

      require_relative "change_requests/engine"

      true
    end

    def setup_loader
      @loader = Zeitwerk::Loader.for_gem.tap do |loader|
        # Generators go through Rails' generator lookup; the test kit is required by the host.
        loader.ignore("#{__dir__}/generators")
        loader.ignore("#{__dir__}/change_requests/rspec.rb")

        # Filing convention, not a namespace: models/request.rb defines ChangeRequests::Request.
        # Every other directory (guards/, commands/, authorization/) is a real namespace.
        loader.collapse("#{__dir__}/change_requests/models")
        loader.collapse("#{__dir__}/change_requests/presenters")

        # Constants Zeitwerk cannot infer from the filename: VERSION, and the whole error taxonomy.
        loader.ignore("#{__dir__}/change_requests/version.rb")
        loader.ignore("#{__dir__}/change_requests/errors.rb")

        # Autoloading it would let an eager load in a headless process require Rails.
        loader.ignore("#{__dir__}/change_requests/engine.rb")

        loader.setup
      end
    end
  end
end

ChangeRequests.setup_loader
ChangeRequests.load_engine!
