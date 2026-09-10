# frozen_string_literal: true

# The domain core is ActiveRecord and ActiveSupport, and nothing else (§2). Requiring it here rather
# than leaving it to the host is what lets `loader.eager_load` succeed in a process that never went
# near Rails - activerecord is a standalone gem, and pulls in activesupport but no railtie.
require "active_record"
require "zeitwerk"

require_relative "change_requests/version"
require_relative "change_requests/errors"

module ChangeRequests
  # Gem-originated events - expiry, the reaper, undeclared-operation cancellation, cooldown stage
  # closing - are attributed to a sentinel rather than to NULL, so "who did this" is answerable for
  # every audit row and no presenter has to branch on nil (§5.5, §19.15).
  #
  # The id is the word "system" rather than "0": actor ids are stored as strings in a column shared
  # with host classes that may have string primary keys, and "0" is a value one of those could
  # legitimately hold.
  SYSTEM_ACTOR = { type: "System", id: "system", label: "System" }.freeze

  class << self
    # The gem's Zeitwerk loader. Exposed so the test suite can eager-load and so a host can inspect
    # or reload it.
    attr_reader :loader

    # Table names are derived, never written (§2, §4): `ChangeRequests::Stage` finds
    # `change_request_stages` without any `self.table_name`. Defining this here - in the file loaded
    # before engine.rb - is what makes it stick: `isolate_namespace` installs its own
    # `table_name_prefix` only `unless mod.respond_to?(:table_name_prefix)`, so ours wins. It also
    # applies headless, where no engine is loaded at all.
    #
    # `Request` is the single exception and sets its table name explicitly, since it would otherwise
    # derive `change_request_requests`.
    def table_name_prefix = "change_request_"

    # Always an instance, never nil, whether or not `configure` has been called (§10).
    def config = @config ||= Configuration.new

    def configure
      yield(config)

      config
    end

    # Loads the Rails integration layer if Rails is here and it is not loaded already. Idempotent,
    # and safe to call at any point.
    #
    # It runs automatically when the gem is required, which is all a normal Rails host needs:
    # `config/application.rb` loads Rails before `Bundler.require` reaches the gem. It is public
    # because that order is not guaranteed - anything that requires this gem *before* Rails gets the
    # domain core and no engine, and `require` is idempotent, so the automatic attempt never comes
    # round again. A host in that position calls this once Rails is up. `spec/dummy` is exactly such
    # a host, which is how the omission was found.
    def load_engine!
      # This method is the seam itself, so it holds the only two references the domain is allowed:
      # the engine it may load, and the Rails constant that decides whether to. Both are guarded by
      # `defined?`, which never raises on a missing constant - they are what *implements* §2's rule
      # rather than breaking it. Every other domain file is held to it without exception.
      #
      # Fully qualified: a host with its own top-level `Engine` would otherwise satisfy this and
      # silently keep ours from loading.
      # archspec:disable-next-line dependencies.forbid -- the loader must name what it loads (§1)
      return false if defined?(ChangeRequests::Engine)
      # archspec:disable-next-line constants.forbid -- the guard that makes the Rails layer opt-in (§1)
      return false unless defined?(::Rails::Engine)

      require_relative "change_requests/engine"

      true
    end

    def setup_loader
      @loader = Zeitwerk::Loader.for_gem.tap do |loader|
        # Generators are loaded by Rails' own generator lookup; the host test kit is explicitly
        # required by the host (§2).
        loader.ignore("#{__dir__}/generators")
        loader.ignore("#{__dir__}/change_requests/rspec.rb")

        # `models/` and `presenters/` are a filing convention, not a namespace: `models/request.rb`
        # defines `ChangeRequests::Request` and `presenters/request_presenter.rb` defines
        # `ChangeRequests::RequestPresenter`, as §3 and §11 name them. Every other directory -
        # `guards/`, `commands/`, `authorization/`, `execution/` - really is a namespace and is not
        # collapsed.
        loader.collapse("#{__dir__}/change_requests/models")
        loader.collapse("#{__dir__}/change_requests/presenters")

        # Both files hold constants Zeitwerk cannot infer from their name - version.rb defines
        # VERSION rather than Version, errors.rb the whole taxonomy rather than an Errors namespace -
        # so both are required above instead.
        loader.ignore("#{__dir__}/change_requests/version.rb")
        loader.ignore("#{__dir__}/change_requests/errors.rb")

        # The engine is the one file that touches Rails (§1). Autoloading it would let an eager load
        # in a headless process require Rails, so it is required below instead - and only when the
        # host has already loaded Rails itself.
        loader.ignore("#{__dir__}/change_requests/engine.rb")

        loader.setup
      end
    end
  end
end

ChangeRequests.setup_loader

# Rails integration is opt-in by presence: a host that has Rails gets the engine, a rake task or a
# bare ActiveRecord connection gets the domain core and nothing else (§1, §2).
ChangeRequests.load_engine!
