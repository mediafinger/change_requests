# frozen_string_literal: true

require "rails_helper"

# In a subprocess, because the assertion is the exit status a host's CI reads - and because the
# task's own `exit 1` would take this process with it.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "rake change_requests:verify (§6.12 point 6)" do
  def verify(registry)
    ruby_status("spec/integration/rake_verify_script.rb", registry)
  end

  it "is supplied by the engine, so a host requires nothing to get it" do
    expect(ChangeRequests::Engine.paths["lib/tasks"].existent)
      .to include(a_string_ending_with("lib/tasks/change_requests.rake"))
  end

  describe "an empty registry" do
    it "exits 0, there being nothing to be wrong" do
      output, status = verify("empty")

      expect(status).to eq(0)
      expect(output).to include("0 operations verified")
    end
  end

  describe "a sound registry" do
    it "exits 0 and reports what it verified" do
      output, status = verify("sound")

      expect(status).to eq(0)
      expect(output).to include("1 operation verified")
    end
  end

  describe "an unsound registry" do
    it "exits non-zero, so CI fails on it" do
      _output, status = verify("unsound")

      expect(status).to eq(1)
    end

    it "prints the problems, naming the operation and what is wrong with it" do
      output, = verify("unsound")

      expect(output).to include("orders.pay")
      expect(output).to include("Orders::NoSuchThing")
    end
  end
end
