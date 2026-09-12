# frozen_string_literal: true

require "rails_helper"

# `Refusal#i18n_key` decides which key every refusal looks up; `config/locales/en.yml` is the only
# place the wording lives, and `Guards::Base::REASONS` the only place the symbol does. This spec is
# the hinge between the three, in both directions: a reason cannot ship without a translation, and a
# translation cannot outlive the reason it was written for (§7, §5.9).
RSpec.describe ChangeRequests::Refusal do
  subject(:translations) { YAML.safe_load_file(path).fetch("en").fetch("change_requests") }

  let(:path) { File.expand_path("../../config/locales/en.yml", __dir__) }
  let(:errors) { translations.fetch("errors") }
  let(:reasons) { ChangeRequests::Guards::Base::REASONS.map(&:to_s) }

  # Every class that carries a reason falls back to its own name underscored when raised without
  # one (Refusal#i18n_key), so each needs a key too.
  let(:error_keys) do
    ChangeRequests.constants.map { |name| ChangeRequests.const_get(name) }
                  .select { |const| const.is_a?(Class) && const <= ChangeRequests::Error }
                  .select { |const| const.ancestors.include?(described_class) }
                  .map(&:error_key)
  end

  it "ships in the gem, which is what makes the packaging spec's pending example go green" do
    expect(File).to exist(path)
  end

  it "is loaded by the engine without the engine doing anything" do
    expect(I18n.load_path).to include(path)
  end

  describe "every reason has a translation" do
    it "covers the whole vocabulary, so a new reason cannot ship untranslated" do
      expect(reasons - errors.keys).to be_empty
    end

    it "covers every error class raised without a reason" do
      expect(error_keys - errors.keys).to be_empty
    end

    it "resolves each of them through the key the error actually builds" do
      missing = reasons.reject do |reason|
        I18n.exists?("#{described_class::I18N_SCOPE}.#{reason}")
      end

      expect(missing).to be_empty
    end

    it "says something, rather than echoing the symbol back" do
      echoes = errors.select { |key, text| text.tr(" ", "_").downcase.delete(".") == key }

      expect(echoes).to be_empty
    end
  end

  # The reverse: a vocabulary that only ever grows accumulates symbols nothing raises, and a
  # translation for a symbol nothing raises is a promise about behaviour the gem does not have.
  describe "every translation has a reason" do
    it "adds no error key that is neither a reason nor an error class" do
      expect(errors.keys - reasons - error_keys).to be_empty
    end

    # Guards return them; Commands::Create, Reject, Comment, Cancel and ClaimExecution raise the
    # argument ones directly. M3a-5 took :override_not_permitted off this list.
    it "is raised somewhere in lib/, or is one of the two still held back" do
      pending_m3a = %w(quorum_not_met transition_error)
      source = Dir[File.expand_path("../../lib/**/*.rb", __dir__)].map { |f| File.read(f) }.join

      unraised = (reasons + error_keys).uniq.reject do |name|
        pending_m3a.include?(name) || source.include?(":#{name}") || source.include?(name.camelize)
      end

      expect(unraised).to be_empty
    end
  end

  describe "the stage and quorum namespaces (§5.9)" do
    # The host names every stage - `op.workflow` invents none - so the gem has no name to translate
    # and ships neither namespace. Both are comment blocks showing a host how to add their own.
    it "ships no stage or quorum names of its own" do
      expect(translations.keys).to eq(%w(errors))
    end

    it "humanizes every stage name, there being no entry to prefer" do
      change_request = build_request

      expect(build_stage(change_request, name: "sign_off").label).to eq("Sign off")
    end

    it "reads a name a host does translate" do
      change_request = build_request
      stage = build_stage(change_request, name: "sign_off")

      with_translations("change_requests.stages.sign_off" => "Director sign-off")

      expect(stage.label).to eq("Director sign-off")
    end

    it "leaves a nameless quorum to borrow its stage's label (§5.9)" do
      change_request = build_request
      stage = build_stage(change_request, name: "operational")

      expect(build_quorum(stage, name: nil).label).to eq("Operational")
    end
  end

  describe "what the messages actually say" do
    it "words the requester rule as the person being refused would read it" do
      expect(errors.fetch("requester")).to eq("You cannot decide on your own request.")
    end

    # These strings are tooltips, not developer hints: a host's end user should never be told to
    # edit an initializer.
    it "names no configuration key" do
      offenders = errors.select { |_key, text| text.match?(/config\.|t\.may_|op\.|§/) }

      expect(offenders).to be_empty
    end
  end
end
