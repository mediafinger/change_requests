# frozen_string_literal: true

RSpec.describe ChangeRequests::Translation do
  # M0-4 built this against a gem that required only zeitwerk, where I18n could genuinely be absent.
  # M1a-1 changed that: the domain core is ActiveRecord (§2), ActiveRecord brings ActiveSupport, and
  # ActiveSupport brings the i18n gem. So I18n now arrives with the gem whether a host asked for it
  # or not, and the interesting claim is no longer "it copes without I18n" but "it copes without a
  # *translation*" - which is the state every key is in until M1b-13 writes the locale file.
  #
  # The unavailable branch is kept and still tested: it costs nothing, and this module is also what
  # §5.9's stage and quorum labels will go through.
  def self.headless
    <<~'RUBY'
      require "change_requests"

      puts "rails=#{defined?(Rails) ? "loaded" : "absent"}"
      puts "i18n=#{defined?(I18n) ? "loaded" : "absent"}"
      puts "translated=#{ChangeRequests::Translation.translate("change_requests.errors.x", default: "x")}"
      puts "message=#{ChangeRequests::NotApprovable.new(reason: :requester).message}"
    RUBY
  end

  describe "in a process that loaded nothing but this gem" do
    subject(:probe) { ruby_probe(self.class.headless) }

    it "still has no Rails, which is the guarantee that matters (§15.5)" do
      expect(probe).to include("rails=absent")
    end

    # Not a failure - a consequence of §2's dependency on ActiveRecord, recorded so the next person
    # does not read `available?` as something that can be false in an ordinary process.
    it "does have I18n, because ActiveSupport brings it" do
      expect(probe).to include("i18n=loaded")
    end

    it "returns the default when nothing defines the key" do
      expect(probe).to include("translated=x")
    end

    it "still gives an error a legible message" do
      expect(probe).to include("message=requester")
    end
  end

  describe ".available?" do
    it "is true when I18n is there, which since M1a-1 is always" do
      expect(described_class).to be_available
    end

    it "is false when it is not, which now takes hiding the constant to arrange" do
      hide_const("I18n")

      expect(described_class).not_to be_available
    end
  end

  describe ".translate" do
    it "delegates to I18n when it is available, passing the default through" do
      calls = with_i18n(returning: "Not pending")

      result = described_class.translate("change_requests.errors.not_pending", default: "not_pending")

      expect(result).to eq("Not pending")
      expect(calls).to eq([{ key: "change_requests.errors.not_pending",
                             options: { default: "not_pending" } }])
    end

    it "returns the default rather than raising when I18n is not there at all" do
      hide_const("I18n")

      expect(described_class.translate("change_requests.errors.not_pending", default: "not_pending"))
        .to eq("not_pending")
    end

    # Not a stub: this is the real I18n, with no locale file defining the key.
    it "falls back to the default when I18n has no translation for the key" do
      expect(described_class.translate("change_requests.errors.nothing_defines_this", default: "fallback"))
        .to eq("fallback")
    end
  end
end
