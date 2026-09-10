# frozen_string_literal: true

# §15.4. `spec.files` is built by rejecting paths from `git ls-files`, which means a new directory
# ships by default and a *renamed* one silently stops shipping. The failure mode is a released gem
# that raises on `rails g change_requests:install` because a template is missing - discovered by an
# adopter, not by CI.
# rubocop:disable-next RSpec/DescribeClass
RSpec.describe "the packaged gem" do
  subject(:packaged) { Gem::Specification.load("change_requests.gemspec").files }

  # Directories the engine and the generators need at runtime. Listed whether or not they exist yet,
  # so that M6 and M7 cannot add one and forget to check it ships: the assertion turns itself on the
  # moment the directory appears in the repository.
  def self.required_at_runtime
    %w(
      app/controllers
      app/helpers
      app/views
      config/locales
      config/routes.rb
      lib/change_requests
      lib/generators
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

  # §15.4's second assertion. Vacuous until M7 writes the generators, and meaningful the moment it
  # does - a template that exists on disk but is missing from `spec.files` is the exact bug this
  # spec is here to catch.
  describe "generator templates" do
    it "packages every template a generator will copy" do
      templates = Dir["lib/generators/**/templates/**/*"].select { |path| File.file?(path) }

      expect(templates - packaged).to be_empty
    end
  end
end
