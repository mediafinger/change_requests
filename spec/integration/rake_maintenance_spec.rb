# frozen_string_literal: true

require "rails_helper"

# In a subprocess, because what a host's cron reads is the exit status and the line on stdout -
# neither of which an in-process call to Maintenance would exercise.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "the change_requests maintenance rake tasks (§8, §5.11)" do
  def run(task, *)
    ruby_status("spec/integration/rake_maintenance_script.rb", task, *)
  end

  it "are supplied by the engine, so a host requires nothing to get them" do
    tasks = ChangeRequests::Engine.paths["lib/tasks"].existent

    expect(tasks).to include(a_string_ending_with("lib/tasks/change_requests.rake"))
  end

  describe "change_requests:expire_stale" do
    subject(:result) { run("expire_stale") }

    it "exits 0" do
      expect(result.last).to eq(0)
    end

    it "reports how many it moved" do
      expect(result.first).to include("ChangeRequests: expired 1 request.")
    end
  end

  describe "change_requests:reap_stuck_executions" do
    subject(:result) { run("reap_stuck_executions") }

    it "exits 0" do
      expect(result.last).to eq(0)
    end

    it "reports how many it moved" do
      expect(result.first).to include("ChangeRequests: reaped 1 request.")
    end
  end

  describe "change_requests:cancel_undeclared" do
    subject(:result) { run("cancel_undeclared") }

    it "exits 0" do
      expect(result.last).to eq(0)
    end

    it "reports how many it moved" do
      expect(result.first).to include("ChangeRequests: canceled 1 request.")
    end
  end

  # A sweep that moved nothing is not an error, and cron should not mail about it.
  describe "a sweep with nothing to do" do
    subject(:result) { run("expire_stale", "empty") }

    it "exits 0 and says zero" do
      expect(result.last).to eq(0)
      expect(result.first).to include("expired 0 requests.")
    end
  end

  # The crontab in docs/05 is the one the tasks are named for, which is the half of that document
  # a rename would silently break.
  describe "the documented schedule" do
    subject(:scheduling) { File.read("docs/05_execution_and_idempotency.md") }

    it "names the two tasks it puts on a schedule" do
      expect(scheduling).to include("change_requests:expire_stale")
      expect(scheduling).to include("change_requests:reap_stuck_executions")
    end

    # §5.11: a missing declaration is as likely to be a deploy accident as a deliberate removal,
    # and `canceled` is final - so this one is documented as an operator's decision, not cron's.
    it "keeps cancel_undeclared off the crontab, and says why" do
      crontab = scheduling[/```cron\n(.*?)```/m, 1]

      expect(crontab).not_to include("cancel_undeclared")
      expect(scheduling).to include("change_requests:cancel_undeclared")
    end
  end
end
