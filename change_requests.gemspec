# frozen_string_literal: true

require_relative "lib/change_requests/version"

Gem::Specification.new do |spec|
  spec.required_ruby_version = ">= 4.0.0" # it likely works under 3.2, but is untested and not supported

  spec.name = "change_requests"
  spec.version = ChangeRequests::VERSION
  spec.authors = ["Andreas Finger"]
  spec.email = ["webmaster@mediafinger.com"]

  spec.summary = "Enforce approval workflows on any guarded action in your Rails app."
  spec.description = <<~DESC
    ChangeRequests puts an approval gate in front of any action in your Rails application. Instead of running a guarded operation immediately, you record it as a change request — the service class, the method, and its arguments — and it stays pending until one ore more other actors approve. Nothing executes until someone other than the requester has signed off.

    Each request moves through a guarded lifecycle: pending, approved, successful or failed, with cancellation and comments available at any point before it reaches a final state. Every transition is a small command object that validates the actor's permissions and the current status before touching the record, so invalid transitions raise rather than silently succeed. Failed requests keep their approval and can be retried.

    The engine makes no assumptions about your user model. You tell it which controller methods return the current actor and their permissions, choose which routes to mount, and it stays out of the way of the rest of your app. Reference views ship with it for a working approvals screen, and every one of them can be replaced or overridden without forking the gem.
  DESC

  spec.homepage = "https://github.com/mediafinger/change_requests"
  spec.license = "MIT"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/mediafinger/change_requests"
  spec.metadata["changelog_uri"] = "https://github.com/mediafinger/change_requests/blob/main/CHANGELOG.md"

  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w(git ls-files -z), chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w(bin/ gemfiles/ tasks/ Archspec.rb Gemfile .gitignore .rspec spec/ .github/
                          .rubocop.yml .ruby-version))
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # the only runtime-dependencies
  #
  spec.add_dependency "activerecord",  ">= 8.1"
  spec.add_dependency "activesupport", ">= 8.1"
  spec.add_dependency "railties",      ">= 8.1"
  spec.add_dependency "zeitwerk",      ">= 2.6"

  # general development and test dependencies
  spec.add_development_dependency "amazing_print",                  ">= 1.8"
  spec.add_development_dependency "archspec",                       ">= 1.1"
  spec.add_development_dependency "bundler",                        ">= 2.2"
  spec.add_development_dependency "bundler-audit",                  ">= 0.9"
  spec.add_development_dependency "irb",                            ">= 1.15"
  spec.add_development_dependency "rake",                           ">= 13.2"
  spec.add_development_dependency "rspec",                          "~> 3.13"
  spec.add_development_dependency "rubocop",                        "~> 1.75"
  spec.add_development_dependency "rubocop-rake",                   "~> 0.7"
  spec.add_development_dependency "rubocop-rspec",                  "~> 3.10"

  # the dummy app and the specs that run against it - PostgreSQL only, deliberately no sqlite3
  spec.add_development_dependency "activejob",                      ">= 8.1"
  spec.add_development_dependency "database_cleaner-active_record", ">= 2.2"
  spec.add_development_dependency "pg",                             ">= 1.5"
  spec.add_development_dependency "rspec-rails",                    ">= 7.1"
end
