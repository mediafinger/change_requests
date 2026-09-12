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
    def table_name_prefix
      "change_request_"
    end

    def config
      @config ||= Configuration.new
    end

    # The declaration registry (§6.12). Memoised for the same reason as config: initializers
    # accumulate into it.
    def operations
      @operations ||= Operations.new
    end

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

    # The host-facing entry point (§6.5), wrapping Commands::Create. The key is positional and the
    # rest are keywords because this is the call every host writes, and it reads better that way.
    # It adds nothing else: the errors are Create's, unrescued.
    def request!(operation_key, requester:, payload: {}, tenant: nil)
      Commands::Create.call(operation_key: operation_key, requester: requester,
                            payload: payload, tenant: tenant)
    end

    # §8's background mode, on the same terms as the engine: idempotent, public, and guarded so
    # requiring the gem in a process without ActiveJob defines no job at all. A host that loads
    # ActiveJob after this gem calls it again - the engine does that automatically on_load.
    def load_execution_job!
      # archspec:disable-next-line dependencies.forbid -- the loader must name what it loads (§1)
      return false if defined?(ChangeRequests::Execution::Job)
      # archspec:disable-next-line constants.forbid -- the guard that keeps ActiveJob optional (§8)
      return false unless defined?(::ActiveJob::Base)

      require_relative "change_requests/execution/job"

      true
    end

    # What a headless process asks before trusting `execution_mode = :background`.
    def background_available?
      # archspec:disable-next-line dependencies.forbid -- the same reference, as a question (§8)
      defined?(ChangeRequests::Execution::Job) ? true : false
    end

    # The configured job class, resolved at enqueue time and never held: a reloading application
    # redefines it, and §10 makes the setting a string for that reason.
    def background_job!
      job = config.job_class.to_s.safe_constantize

      return job unless job.nil?

      fail ConfigurationError,
           "config.execution_mode is :background but config.job_class " \
           "(#{config.job_class.inspect}) does not resolve. ChangeRequests::Execution::Job is " \
           "defined only where ActiveJob is loaded, which this process has not done (§8)."
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
        # lib/tasks holds .rake files the engine loads, not constants under a Tasks namespace.
        loader.ignore("#{__dir__}/generators")
        loader.ignore("#{__dir__}/tasks")
        loader.ignore("#{__dir__}/change_requests/rspec.rb")

        # Filing convention, not a namespace: models/request.rb defines ChangeRequests::Request.
        # Every other directory (guards/, commands/, authorization/) is a real namespace.
        loader.collapse("#{__dir__}/change_requests/models")
        loader.collapse("#{__dir__}/change_requests/presenters")

        # Constants Zeitwerk cannot infer from the filename: VERSION, and the whole error taxonomy.
        loader.ignore("#{__dir__}/change_requests/version.rb")
        loader.ignore("#{__dir__}/change_requests/errors.rb")

        # Autoloading either would let an eager load pull in something optional: Rails for the
        # engine, ActiveJob for the job - which defines nothing at all when ActiveJob is absent.
        loader.ignore("#{__dir__}/change_requests/engine.rb")
        loader.ignore("#{__dir__}/change_requests/execution/job.rb")

        loader.setup
      end
    end
  end
end

ChangeRequests.setup_loader
ChangeRequests.load_engine!
ChangeRequests.load_execution_job!
