# frozen_string_literal: true

require "English"

# Some guarantees are only observable in a process that loaded something this suite deliberately did
# not - Rails, for the engine specs (§1), and its absence for the headless ones (§15.5). Requiring
# Rails inside the suite would make those assertions depend on file order, so they run out of
# process instead.
module Subprocess
  # Runs `body` with the gem's lib/ on the load path and returns everything it printed. Raises with
  # the output when the child fails, so a broken probe reads as a broken probe rather than as an
  # empty string that fails a later expectation.
  def ruby_probe(body)
    output = IO.popen(["ruby", "-Ilib", "-e", body], err: %i(child out), &:read)

    fail "probe exited #{$CHILD_STATUS.exitstatus}:\n#{output}" unless $CHILD_STATUS.success?

    output
  end
end

RSpec.configure do |config|
  config.include Subprocess
end
