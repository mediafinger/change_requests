# frozen_string_literal: true

# The subject is the packaging manifest itself, so there is no class to describe.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "change_requests.gemspec" do
  subject(:gemspec) { Gem::Specification.load(File.expand_path("../change_requests.gemspec", __dir__)) }

  def requirement_for(dependencies, name)
    dependencies.find { |d| d.name == name }&.requirement&.to_s
  end

  describe "runtime dependencies" do
    it "depends on ActiveRecord, ActiveSupport, railties and Zeitwerk, and on nothing else" do
      expect(gemspec.runtime_dependencies.map(&:name))
        .to contain_exactly("activerecord", "activesupport", "railties", "zeitwerk")
    end

    it "allows the Rails versions the engine supports" do
      expect(requirement_for(gemspec.runtime_dependencies, "activerecord")).to eq(">= 7.1")
      expect(requirement_for(gemspec.runtime_dependencies, "activesupport")).to eq(">= 7.1")
      expect(requirement_for(gemspec.runtime_dependencies, "railties")).to eq(">= 7.1")
      expect(requirement_for(gemspec.runtime_dependencies, "zeitwerk")).to eq(">= 2.6")
    end

    it "does not depend on a database adapter - PostgreSQL-only is a documented requirement, not a constraint" do
      expect(gemspec.runtime_dependencies.map(&:name)).not_to include("pg")
    end
  end

  describe "development dependencies" do
    it "carries what the dummy app and its specs need" do
      names = gemspec.development_dependencies.map(&:name)

      expect(names).to include("activejob", "database_cleaner-active_record", "pg", "rspec-rails")
    end

    it "never pulls in sqlite3 - the gem is PostgreSQL-only and prepares no second adapter" do
      expect(gemspec.dependencies.map(&:name)).not_to include("sqlite3")
    end
  end

  describe "packaging" do
    it "requires Ruby 4" do
      expect(gemspec.required_ruby_version.to_s).to eq(">= 4.0.0")
    end

    it "excludes the CI matrix gemfiles from the released gem" do
      expect(gemspec.files.grep(%r{\Agemfiles/})).to be_empty
    end
  end
end
