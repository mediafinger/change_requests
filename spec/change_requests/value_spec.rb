# frozen_string_literal: true

RSpec.describe ChangeRequests::Value do
  describe "TONES" do
    # M6's CSS class contract and M5-7's as_json both read this list. Growing it is a decision.
    it "is exactly the closed set" do
      expect(described_class::TONES).to eq(%i(neutral primary success warning danger))
    end

    it "is frozen" do
      expect(described_class::TONES).to be_frozen
    end
  end

  describe ".tone!" do
    it "accepts every member" do
      expect(described_class::TONES.map { |tone| described_class.tone!(tone) }).to eq(described_class::TONES)
    end

    it "accepts a string, as a host's own config would hold one" do
      expect(described_class.tone!("danger")).to eq(:danger)
    end

    it "refuses anything else, naming the set" do
      expect { described_class.tone!(:info) }.to raise_error(ArgumentError, /:info.*neutral, primary/)
    end

    it "refuses nil" do
      expect { described_class.tone!(nil) }.to raise_error(ArgumentError)
    end
  end

  describe "in a process that loaded nothing but this gem" do
    subject(:probe) do
      ruby_probe(<<~'RUBY')
        require "change_requests"
        ChangeRequests.loader.eager_load

        puts "rails=#{defined?(Rails) ? "loaded" : "absent"}"
        puts "action_view=#{defined?(ActionView) ? "loaded" : "absent"}"
        puts "field=#{ChangeRequests::Value::Field.new(key: :member_id, value: 42).label}"
        puts "status=#{ChangeRequests::Value::Status.new(key: :failed, tone: :danger).label}"
      RUBY
    end

    it "loads without Rails or ActionView (§11)" do
      expect(probe).to include("rails=absent", "action_view=absent")
    end

    it "labels with no locale file" do
      expect(probe).to include("field=Member", "status=Failed")
    end
  end
end
