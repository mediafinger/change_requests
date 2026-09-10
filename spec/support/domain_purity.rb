# frozen_string_literal: true

require "prism"

# The dependency rule from §2, enforced in CI rather than by memory:
#
#   nothing under lib/change_requests/{models,operation,guards,commands,authorization,execution,
#   presenters} may reference ActionController, ActionView, Rails, or any constant under app/.
#
# The rule is what keeps `spec/integration/headless_spec.rb` honest and what would make a future
# split into `change_requests` + `change_requests-rails` a `git mv` rather than a rewrite (§1).
#
# It is applied to the whole domain layer, not only the seven directories §2 lists, because every
# file under lib/change_requests/ except the engine is domain code and the same rule serves it.
#
# **Comments are excluded, deliberately.** Half the value of these files is prose explaining why the
# gem does not touch Rails, and a naive grep flags exactly the sentences that document the rule.
# Comment text is blanked out by source location before matching, so the check reads code only.
module DomainPurity
  FORBIDDEN = /\b(?:ActionController|ActionView|ActionDispatch|ActiveJob|Rails)\b/

  # The one file in lib/change_requests/ allowed to know Rails exists (§1). It is required only when
  # the host has already loaded Rails, and the Zeitwerk loader ignores it.
  EXEMPT = %w(engine.rb).freeze

  module_function

  def files(root: Dir.pwd)
    Dir[File.join(root, "lib/change_requests/**/*.rb")]
      .reject { |path| EXEMPT.include?(File.basename(path)) }
      .sort
  end

  # => [[line_number, source_line], ...]
  def offences(source)
    code_only(source).lines.each_with_index.filter_map do |line, index|
      [index + 1, line.rstrip] if line.match?(FORBIDDEN)
    end
  end

  def offences_in(path)
    offences(File.read(path))
  end

  # Replaces every comment with spaces, preserving line and column numbers so a reported line number
  # still points at the right place.
  def code_only(source)
    lines = source.lines

    Prism.parse(source).comments.each do |comment|
      location = comment.location
      line     = lines[location.start_line - 1] or next
      width    = location.end_column - location.start_column

      line[location.start_column, width] = " " * width
    end

    lines.join
  end
end
