# frozen_string_literal: true

# Bundler::Audit::Task shells out with no arguments, and `bundler-audit check` resolves
# "Gemfile.lock" against the project root, ignoring BUNDLE_GEMFILE. Under the CI matrix gemfile
# there is no root Gemfile.lock, so it fails. Resolve the active gemfile's lockfile instead.
module BundleAudit
  module_function

  # Relative, not absolute: bundler-audit joins --gemfile-lock onto the root it scans
  # (Scanner#initialize). Bundler exports BUNDLE_GEMFILE absolute under `bundle exec`.
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
