# frozen_string_literal: true

# Described by name, not by constant: this suite deliberately never loads Rails, so the engine does
# not exist in this process.
RSpec.describe "ChangeRequests::Engine" do
  # One probe per scenario, several assertions each: booting Rails costs about half a second, and the
  # facts below are all properties of the same load.
  def self.with_rails
    <<~'RUBY'
      require "rails"
      require "change_requests"
      ChangeRequests.loader.eager_load

      puts "engine=#{defined?(ChangeRequests::Engine) ? "defined" : "absent"}"
      puts "isolated=#{ChangeRequests::Engine.isolated?}"
      puts "railtie_namespace=#{ChangeRequests.railtie_namespace}"
      puts "table_name_prefix=#{ChangeRequests.table_name_prefix}"
      puts "routes_path=#{ChangeRequests::Engine.paths["config/routes.rb"].existent.size}"
    RUBY
  end

  def self.without_rails
    <<~'RUBY'
      require "change_requests"
      ChangeRequests.loader.eager_load

      puts "rails=#{defined?(Rails) ? "loaded" : "absent"}"
      puts "engine=#{defined?(ChangeRequests::Engine) ? "defined" : "absent"}"
    RUBY
  end

  # A Rails application small enough to build in a heredoc, and real enough to run the engine's
  # initializers. M0-6's dummy app replaces this for everything else; here it is the only way to
  # prove `config.after_initialize` is wired at all.
  def self.booting(configure)
    <<~RUBY
      require "rails"
      require "change_requests"
      require "tmpdir"

      #{configure}

      app = Class.new(Rails::Application) do
        config.eager_load     = false
        config.root           = Dir.mktmpdir
        config.secret_key_base = "x" * 64
        config.logger         = Logger.new(IO::NULL)
      end
      Object.const_set(:ProbeApp, app)

      begin
        ProbeApp.initialize!
        puts "boot=ok"
        puts "table_name_prefix=" + ChangeRequests.table_name_prefix
        puts "routes=" + ChangeRequests::Engine.routes.routes.size.to_s
      rescue ChangeRequests::ConfigurationError => e
        puts "boot=refused"
        puts "message=" + e.message.lines.first.strip
      end
    RUBY
  end

  def self.registering_an_actor_type
    <<~RUBY
      ChangeRequests.configure do |c|
        c.actor_type("User") do |t|
          t.label       = ->(user) { user.name }
          t.permissions = ->(user) { user.roles }
        end
      end
    RUBY
  end

  context "when the host has loaded Rails" do
    subject(:probe) { ruby_probe(self.class.with_rails) }

    it "defines the engine" do
      expect(probe).to include("engine=defined")
    end

    it "isolates the namespace, so no constant or route leaks into the host (§1)" do
      expect(probe).to include("isolated=true")
      expect(probe).to include("railtie_namespace=ChangeRequests::Engine")
    end

    # The regression M0-2 exists to prevent: `isolate_namespace` installs its own
    # `table_name_prefix` unless the module already responds to one, and its version yields
    # `change_requests_stages` rather than §4's `change_request_stages`. Deleting the definition from
    # the entrypoint really does flip this to "change_requests_".
    it "does not let isolate_namespace overwrite the table name prefix" do
      expect(probe).to include("table_name_prefix=change_request_")
    end

    it "ships a route file where the engine looks for one" do
      expect(probe).to include("routes_path=1")
    end
  end

  context "when the host has no Rails" do
    subject(:probe) { ruby_probe(self.class.without_rails) }

    # §1: the domain core is usable from a job, a console, an API or a rake task, and eager loading
    # must not drag Rails in through the back door.
    it "loads the domain core without Rails" do
      expect(probe).to include("rails=absent")
    end

    it "defines no engine at all" do
      expect(probe).to include("engine=absent")
    end
  end

  context "when a real application boots" do
    subject(:probe) { ruby_probe(self.class.booting(self.class.registering_an_actor_type)) }

    it "completes initialization" do
      expect(probe).to include("boot=ok")
    end

    it "keeps the table name prefix through a full initialization, not just a bare require" do
      expect(probe).to include("table_name_prefix=change_request_")
    end

    it "draws an empty route set - controllers and views are M6" do
      expect(probe).to include("routes=0")
    end
  end

  # A misconfiguration is a deploy-time problem with an actionable message, not a 500 on the first
  # request that happens to touch the gem (§10).
  context "when a real application boots misconfigured" do
    subject(:probe) { ruby_probe(self.class.booting("")) }

    it "refuses to finish booting" do
      expect(probe).to include("boot=refused")
    end

    it "says what is wrong" do
      expect(probe).to include("message=ChangeRequests is misconfigured:")
    end
  end
end
