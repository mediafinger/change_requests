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

  def run_ruby(*)
    output, status = ruby_status(*)

    fail "probe exited #{status}:\n#{output}" unless status.zero?

    output
  end

  # For probes whose exit status is the assertion - a rake task that must fail on an unsound
  # registry proves nothing if a non-zero exit raises here instead.
  def ruby_status(*arguments)
    output = IO.popen(["ruby", "-Ilib", *arguments], err: %i(child out), &:read)

    [output, $CHILD_STATUS.exitstatus]
  end
end

RSpec.configure do |config|
  config.include Subprocess
end
