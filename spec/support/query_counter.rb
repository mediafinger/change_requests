# frozen_string_literal: true

# Counts the SQL a block actually issues.
#
# §11 promises query counts rather than "it feels fast": a presenter built with
# `resolve_actors: false` renders a complete page with **zero** queries against host tables, and
# a collection costs one query per actor type rather than one per row. A promise nobody counts is
# not a promise, and M4-2, M5-2 and M5-6 all rest on this.
module QueryCounter
  # Transaction control and schema reflection are not the work being measured. Rails emits
  # SAVEPOINTs around every `with_lock`, and the suite runs each example inside a transaction.
  IGNORED = /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE SAVEPOINT|SHOW|SET)\b/i

  module_function

  def capture
    captured = []

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached] || payload[:sql].match?(IGNORED)

      captured << payload[:sql]
    end

    yield

    captured
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end

RSpec::Matchers.define :issue_queries do |expected|
  supports_block_expectations

  match do |block|
    @queries = QueryCounter.capture(&block)

    @queries.size == expected
  end

  failure_message do
    "expected #{expected} queries, got #{@queries.size}:\n  #{@queries.join("\n  ")}"
  end

  failure_message_when_negated do
    "expected anything but #{expected} queries, got exactly that"
  end
end

RSpec::Matchers.define :issue_no_queries do
  supports_block_expectations

  match do |block|
    @queries = QueryCounter.capture(&block)

    @queries.empty?
  end

  failure_message do
    "expected no queries, got #{@queries.size}:\n  #{@queries.join("\n  ")}"
  end
end
