# frozen_string_literal: true

require "English"

# For guarantees about what a process did or did not load. Asserting them in-process would make
# them depend on spec file order.
module Subprocess
  # Raises with the child's output on failure, so a broken probe does not read as a failed
  # expectation on an empty string.
  def ruby_probe(body)
    run_ruby("-e", body)
  end

  # Same, for a probe long enough to deserve its own file.
  def ruby_script(path)
    run_ruby(path)
  end

  def run_ruby(*arguments)
    output = IO.popen(["ruby", "-Ilib", *arguments], err: %i(child out), &:read)

    fail "probe exited #{$CHILD_STATUS.exitstatus}:\n#{output}" unless $CHILD_STATUS.success?

    output
  end
end

RSpec.configure do |config|
  config.include Subprocess
end
