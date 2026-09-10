# frozen_string_literal: true

# §2's dependency rule, enforced in CI. The headless spec proves the core *runs* without Rails; this
# proves it cannot quietly acquire a dependency on it between releases, which is the failure that
# would otherwise only show up in someone else's rake task.
RSpec.describe DomainPurity do
  describe "the domain layer" do
    it "has files to check, so a rename cannot make this pass vacuously" do
      expect(described_class.files).not_to be_empty
    end

    described_class.files.each do |path|
      it "#{path.sub("#{Dir.pwd}/", "")} references no Rails constant" do
        relative = path.sub("#{Dir.pwd}/", "")
        offences = described_class.offences_in(path)

        expect(offences).to be_empty, lambda {
          "#{relative} may not reference ActionController, ActionView or Rails (§2):\n" +
            offences.map { |line, text| "  #{line}: #{text}" }.join("\n")
        }
      end
    end

    it "exempts the engine, which is the one file allowed to know Rails exists" do
      expect(described_class.files).not_to include(a_string_ending_with("engine.rb"))
    end
  end

  # The check itself has to be trustworthy: it is the only thing standing between the gem and a
  # `Rails.logger` slipped into a command.
  describe ".offences" do
    it "catches a Rails reference" do
      expect(described_class.offences("def call = Rails.logger.info('hi')"))
        .to eq([[1, "def call = Rails.logger.info('hi')"]])
    end

    it "catches ActionController and ActionView too" do
      expect(described_class.offences("ActionController::Base\nActionView::Base\n").size).to eq(2)
    end

    it "reports the line number, so the failure names the place" do
      source = "class Command\n  def call\n    Rails.env\n  end\nend\n"

      expect(described_class.offences(source).map(&:first)).to eq([3])
    end

    # Half the value of these files is prose explaining why the gem does not touch Rails. A naive
    # grep flags exactly the sentences that document the rule - two such comments exist today.
    it "ignores a full-line comment" do
      expect(described_class.offences("# The core runs with no Rails at all.\n")).to be_empty
    end

    it "ignores a trailing comment without blinding itself to the rest of the line" do
      source = "call_something # unlike Rails, this is fine\nRails.env\n"

      expect(described_class.offences(source).map(&:first)).to eq([2])
    end

    it "does not flag a longer word that merely contains one" do
      expect(described_class.offences("Railsish = 1\nGuardrails.check\n")).to be_empty
    end
  end
end
