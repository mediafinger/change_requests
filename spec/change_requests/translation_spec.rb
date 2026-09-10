# frozen_string_literal: true

RSpec.describe ChangeRequests::Translation do
  describe ".available?" do
    it "is false when I18n was never loaded, which is the headless case" do
      expect(described_class).not_to be_available
    end

    it "is true once I18n is there" do
      with_i18n

      expect(described_class).to be_available
    end
  end

  describe ".translate" do
    it "returns the default rather than raising when I18n is absent" do
      expect(described_class.translate("change_requests.errors.not_pending", default: "not_pending"))
        .to eq("not_pending")
    end

    it "delegates to I18n when it is available, passing the default through" do
      calls = with_i18n(returning: "Not pending")

      result = described_class.translate("change_requests.errors.not_pending", default: "not_pending")

      expect(result).to eq("Not pending")
      expect(calls).to eq([{ key: "change_requests.errors.not_pending",
                             options: { default: "not_pending" } }])
    end
  end
end
