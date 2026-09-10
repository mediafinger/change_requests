# frozen_string_literal: true

# `Bundler::Audit::Task` shells out to `bundler-audit check` with no arguments, and that command
# resolves "Gemfile.lock" against the project root - it does not look at BUNDLE_GEMFILE. The CI
# matrix runs with BUNDLE_GEMFILE=gemfiles/rails_8.1.gemfile, whose lockfile sits beside it and
# whose root Gemfile.lock is never generated, so the stock task fails with
# `Could not find "Gemfile.lock"`.
#
# Resolve the lockfile belonging to the gemfile actually in use instead.
module BundleAudit
  module_function

  # Bundler exports BUNDLE_GEMFILE (as an absolute path) for anything run under `bundle exec`, so the
  # fallback only applies to a bare `rake`.
  #
  # The result is deliberately relative: `bundler-audit` joins `--gemfile-lock` onto the project root
  # it scans (Scanner#initialize), so an absolute path resolves to nonsense.
  def lockfile(env = ENV, root: Dir.pwd)
    path = Pathname.new("#{env.fetch("BUNDLE_GEMFILE", "Gemfile")}.lock")
    path = path.relative_path_from(root) if path.absolute?

    path.to_s
  end

  def check_command(env = ENV)
    ["bundler-audit", "check", "--gemfile-lock", lockfile(env)]
  end

  def update_command
    %w(bundler-audit update)
  end
end
