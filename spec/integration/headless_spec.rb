# frozen_string_literal: true

# Out of process: this suite loads the dummy app, so Rails is defined here whatever the gem does.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "the domain core, headless" do
  subject(:probe) { ruby_script("spec/integration/headless_script.rb") }

  it "never loads Rails" do
    expect(probe).to include("rails=absent")
    expect(probe).to include("action_controller=absent")
  end

  it "still has no Rails by the time it finishes, in case something pulled it in on the way" do
    expect(probe).to include("rails_at_exit=absent")
  end

  it "defines no engine" do
    expect(probe).to include("engine=absent")
  end

  it "eager loads, so a misfiled constant fails here rather than in a host application" do
    expect(probe).to include("eager_load=ok")
  end

  it "derives table names without an engine to install the prefix" do
    expect(probe).to include("table_name_prefix=change_request_")
  end

  it "configures and validates itself" do
    expect(probe).to include("validate=true")
  end

  it "produces an error message with no I18n and no locale files" do
    expect(probe).to include("error_message=requester")
  end

  it "talks to PostgreSQL over a bare ActiveRecord connection" do
    expect(probe).to include("adapter=PostgreSQL")
  end

  # ActiveSupport 8.1 calls JSON.parse positionally and json 3 removed that form, so a child that
  # escaped the bundle would fail on the payload below with no hint as to why.
  it "inherits the bundle's json pin, which every jsonb column depends on" do
    expect(probe).to include("json=2.")
  end

  describe "installing from nothing" do
    # Its own database: nothing here runs in a transaction, so committed rows would leak into every
    # spec that counts them.
    it "runs the install generator's migration and gets all nine tables" do
      expect(probe).to include("tables=9")
    end

    it "cleans up after itself" do
      expect(probe).to include("cleanup=ok")
    end
  end

  # DoD item 5, and the proof the command layer needs no Rails either: create, refuse, approve,
  # approve again, and reach `approved` - all of it driven through the commands a host calls.
  describe "running a request through the commands" do
    it "creates one from the declaration, not from hand-built rows" do
      expect(probe).to include("request=pending")
    end

    # An actor is any object whose class is registered - no ActiveRecord, no host framework.
    it "snapshots the label of a plain Ruby requester" do
      expect(probe).to include("requester_label=Ada Lovelace")
    end

    it "round-trips a jsonb payload" do
      expect(probe).to include("payload_roundtrip=editor")
    end

    it "materialises the workflow the operation describes" do
      expect(probe).to include("materialised=stages=1 quorums=1 permissions=1")
      expect(probe).to include("quorum_threshold=2")
    end

    # No engine, so config/locales/en.yml is not on I18n.load_path and `approval` humanizes.
    it "resolves a stage label through the humanize fallback" do
      expect(probe).to include("stage_label=Approval")
    end

    it "refuses the requester their own approval, with the whole stack and no framework" do
      expect(probe).to include("requester_refused=requester")
    end

    it "holds at pending until the quorum is met" do
      expect(probe).to include("after_one=pending")
    end

    it "reaches approved on the second approval" do
      expect(probe).to include("after_two=approved")
      expect(probe).to include("stage_after_two=closed")
    end

    it "writes the whole trail through Commands::Base#emit" do
      expect(probe)
        .to include("event_kinds=requested,approved,approved,quorum_satisfied,stage_satisfied")
    end

    it "attributes a decision to the actor who made it" do
      expect(probe).to include("event_actor=Grace Hopper")
    end

    # Closing a stage is the gem's own act, so the sentinel is what the trail names - and the
    # sentinel needs no registered actor type, which is the point of it (§19.15).
    it "attributes closing the stage to the System sentinel" do
      expect(probe).to include("closing_actor=System")
    end

    # The model layer is the floor beneath the commands, and it holds with nothing else loaded.
    it "enforces terminal-state protection" do
      expect(probe).to include("terminal_guard=enforced")
    end
  end
end
