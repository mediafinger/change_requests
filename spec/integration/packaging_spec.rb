# frozen_string_literal: true

# spec.files rejects paths from `git ls-files`, so a renamed directory silently stops shipping and
# an adopter finds out when the install generator cannot find a template.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "the packaged gem" do
  subject(:packaged) { Gem::Specification.load("change_requests.gemspec").files }

  # Listed before they exist: each turns itself on when M6 or M7 adds the directory.
  def self.required_at_runtime
    %w(
      app/controllers
      app/helpers
      app/views
      config/locales
      config/routes.rb
      lib/change_requests
      lib/generators
      lib/tasks
    ).freeze
  end

  # The inverse, and just as important: development scaffolding must not be shipped to adopters.
  def self.never_packaged
    %w(
      .github
      Gemfile
      bin
      gemfiles
      spec
      tasks
    ).freeze
  end

  describe "what it must contain" do
    required_at_runtime.each do |path|
      it "packages #{path}" do
        skip "#{path} does not exist yet - it arrives with a later milestone" unless File.exist?(path)

        expect(packaged.grep(/\A#{Regexp.escape(path)}/)).not_to be_empty
      end
    end

    it "packages the gem's own library code" do
      expect(packaged).to include("lib/change_requests.rb", "lib/change_requests/engine.rb")
    end
  end

  describe "what it must not contain" do
    never_packaged.each do |path|
      it "leaves #{path} out" do
        expect(packaged.grep(/\A#{Regexp.escape(path)}/)).to be_empty
      end
    end

    it "leaves the gemspec itself out" do
      expect(packaged).not_to include("change_requests.gemspec")
    end
  end

  # Vacuous until M7 writes the generators.
  describe "generator templates" do
    it "packages every template a generator will copy" do
      templates = Dir["lib/generators/**/templates/**/*"].select { |path| File.file?(path) }

      expect(templates - packaged).to be_empty
    end
  end
end
