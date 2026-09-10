# frozen_string_literal: true

RSpec.describe ChangeRequests::Translation do
  # ActiveSupport depends on the i18n gem, so once the dummy app is loaded I18n is present in this
  # process whether the gem asked for it or not. The claim this module exists to make - that the
  # domain core still produces a message when nothing loaded I18n - is therefore a claim about a
  # *process*, and is asserted in one, the same way §15.5's headless spec works.
  def self.headless
    <<~'RUBY'
      require "change_requests"

      puts "i18n=#{defined?(I18n) ? "loaded" : "absent"}"
      puts "available=#{ChangeRequests::Translation.available?}"
      puts "translated=#{ChangeRequests::Translation.translate("change_requests.errors.x", default: "x")}"
      puts "message=#{ChangeRequests::NotApprovable.new(reason: :requester).message}"
    RUBY
  end

  describe "in a process that never loaded I18n" do
    subject(:probe) { ruby_probe(self.class.headless) }

    it "confirms I18n really is absent, or the rest of this proves nothing" do
      expect(probe).to include("i18n=absent")
    end

    it "reports itself unavailable" do
      expect(probe).to include("available=false")
    end

    it "returns the default instead of raising" do
      expect(probe).to include("translated=x")
    end

    it "still gives an error a legible message" do
      expect(probe).to include("message=requester")
    end
  end

  describe ".available?" do
    it "is true when I18n is there" do
      with_i18n

      expect(described_class).to be_available
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

    # Not a stub: this is the real I18n the dummy app loaded, with no locale file defining the key.
    it "falls back to the default when I18n has no translation for the key" do
      expect(described_class.translate("change_requests.errors.nothing_defines_this", default: "fallback"))
        .to eq("fallback")
    end
  end
end
