# frozen_string_literal: true

require_relative "../../tasks/bundle_audit"

RSpec.describe BundleAudit do
  describe ".lockfile" do
    # Regression: with a CI matrix gemfile active, the stock bundler-audit rake task looked for
    # "Gemfile.lock" in the working directory and failed with `Could not find "Gemfile.lock"`.
    it "resolves the lockfile of the gemfile in use, not the one in the working directory" do
      env = { "BUNDLE_GEMFILE" => "gemfiles/rails_8.1.gemfile" }

      expect(described_class.lockfile(env)).to eq("gemfiles/rails_8.1.gemfile.lock")
    end

    # bundler-audit joins --gemfile-lock onto the project root it scans, so an absolute path - which
    # is exactly what bundler exports under `bundle exec` - resolves to nonsense.
    it "returns a path relative to the project root, not the absolute one bundler exports" do
      env = { "BUNDLE_GEMFILE" => "/repo/gemfiles/rails_8.1.gemfile" }

      expect(described_class.lockfile(env, root: "/repo")).to eq("gemfiles/rails_8.1.gemfile.lock")
    end

    it "falls back to Gemfile.lock when BUNDLE_GEMFILE is unset" do
      expect(described_class.lockfile({})).to eq("Gemfile.lock")
    end
  end

  describe ".check_command" do
    it "tells bundler-audit which lockfile to check" do
      env = { "BUNDLE_GEMFILE" => "gemfiles/rails_8.1.gemfile" }

      expect(described_class.check_command(env))
        .to eq(["bundler-audit", "check", "--gemfile-lock", "gemfiles/rails_8.1.gemfile.lock"])
    end
  end

  describe "the lockfile it resolves for this run" do
    it "exists, so `rake ci` audits a real lockfile" do
      expect(File).to exist(described_class.lockfile)
    end
  end
end
