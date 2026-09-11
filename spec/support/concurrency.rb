# frozen_string_literal: true

require "database_cleaner/active_record"

# The rest of the suite runs each example inside a transaction that is rolled back, which is fast
# and exactly wrong here: a second thread on a second connection cannot see uncommitted rows, so a
# race would have nothing to race over.
#
# Groups tagged `:concurrent` opt out and truncate instead. Only they pay for it - this is what
# `database_cleaner-active_record` has been in the gemspec for since M0-1.
RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.allow_remote_database_url = true
  end

  config.around(:each, :concurrent) do |example|
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean_with(:truncation)

    example.run

    DatabaseCleaner.clean_with(:truncation)
  end
end

# Records when each thread entered and left the section under test, so a spec can ask whether two
# of them were ever inside it at the same time. That is the question `with_lock` exists to answer,
# and it is answerable without breaking anything first.
class Overlap
  def initialize
    @mutex = Mutex.new
    @spans = []
  end

  # Recorded in an ensure: the span is how long a thread was inside the section, which is a fact
  # whether the body returned or raised. Without it the loser of a race - who raises - leaves no
  # span, and two overlapping threads look like one.
  def record
    started = monotonic

    yield
  ensure
    @mutex.synchronize { @spans << [started, monotonic] }
  end

  # True when any two spans intersect - two threads inside the section at once.
  def any?
    @spans.sort.each_cons(2).any? { |(_, first_end), (second_start, _)| second_start < first_end }
  end

  def count
    @spans.size
  end

  private

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
