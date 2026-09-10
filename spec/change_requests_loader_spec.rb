# frozen_string_literal: true

RSpec.describe ChangeRequests do
  # Zeitwerk resolves this without the file having to exist yet, so these assertions hold from M0-2
  # and keep holding once M1a and M5 fill the directories in.
  def cpath_at(relative_path)
    described_class.loader.cpath_expected_at(File.expand_path("../#{relative_path}", __dir__))
  end

  describe ".loader" do
    it "is the gem's Zeitwerk loader" do
      expect(described_class.loader).to be_a(Zeitwerk::Loader)
    end

    it "eager loads without raising, so a misplaced constant fails here and not in production" do
      expect { described_class.loader.eager_load }.not_to raise_error
    end
  end

  describe "collapsed directories" do
    it "treats models/ as a filing convention, not a namespace" do
      expect(cpath_at("lib/change_requests/models")).to eq("ChangeRequests")
    end

    it "treats presenters/ as a filing convention, not a namespace" do
      expect(cpath_at("lib/change_requests/presenters")).to eq("ChangeRequests")
    end

    it "leaves every other directory a real namespace" do
      expect(cpath_at("lib/change_requests/guards")).to eq("ChangeRequests::Guards")
    end

    it "does not define a Models namespace" do
      described_class.loader.eager_load

      expect(defined?(ChangeRequests::Models)).to be_nil
    end
  end

  describe "ignored paths" do
    it "leaves lib/generators to Rails' own generator lookup" do
      expect(cpath_at("lib/generators")).to be_nil
    end

    it "does not expect version.rb to define a Version constant" do
      expect(cpath_at("lib/change_requests/version.rb")).to be_nil
    end

    it "does not expect errors.rb to define an Errors namespace" do
      expect(cpath_at("lib/change_requests/errors.rb")).to be_nil
    end
  end

  describe ".table_name_prefix" do
    it "derives the table names in §4" do
      expect(described_class.table_name_prefix).to eq("change_request_")
    end

    # `isolate_namespace` defines its own `table_name_prefix` - which would yield
    # `change_requests_stages` - only `unless mod.respond_to?(:table_name_prefix)`. Responding to it
    # here, from the file loaded before engine.rb, is what keeps ours. M0-5 asserts the same against
    # a real engine.
    it "is defined before any engine can install its own" do
      expect(described_class).to respond_to(:table_name_prefix)
    end
  end

  describe ".config" do
    it "is never nil, even before configure is called" do
      expect(described_class.config).to be_a(ChangeRequests::Configuration)
    end

    it "is memoised, so configuration accumulates across initializers" do
      expect(described_class.config).to equal(described_class.config)
    end
  end

  describe ".configure" do
    it "yields the memoised config and returns it" do
      yielded = nil

      result = described_class.configure { |config| yielded = config }

      expect(yielded).to equal(described_class.config)
      expect(result).to equal(described_class.config)
    end
  end

  describe "SYSTEM_ACTOR" do
    it "attributes gem-originated events to a sentinel rather than to NULL" do
      expect(described_class::SYSTEM_ACTOR).to eq(type: "System", id: "system", label: "System")
    end

    it "uses a non-numeric id, which no host actor's string primary key can collide with" do
      expect(described_class::SYSTEM_ACTOR[:id]).to eq("system")
    end

    it "is frozen" do
      expect(described_class::SYSTEM_ACTOR).to be_frozen
    end
  end
end
