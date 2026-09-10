# frozen_string_literal: true

require "rails_helper"

ProbeTable.create!(:string_enum_probes)

class StringEnumProbe < ChangeRequests::Record
  self.table_name = "string_enum_probes"

  include ChangeRequests::Concerns::StringEnum

  string_enum :status, %w(pending satisfied closed)
end

RSpec.describe ChangeRequests::Concerns::StringEnum do
  it "exposes the permitted values under the pluralised column name" do
    expect(StringEnumProbe.statuses).to eq(%w(pending satisfied closed))
  end

  it "freezes them, so a caller cannot edit the enum at runtime" do
    expect(StringEnumProbe.statuses).to be_frozen
  end

  describe "validation" do
    it "accepts a permitted value" do
      expect(StringEnumProbe.new(status: "pending")).to be_valid
    end

    # The database CHECK constraint in the generated migration is the floor beneath this (§5.7); the
    # validation is what turns a typo into a readable error instead of a StatementInvalid.
    it "rejects anything else" do
      probe = StringEnumProbe.new(status: "nearly")

      expect(probe).not_to be_valid
      expect(probe.errors[:status]).to include("is not included in the list")
    end

    it "rejects nil, since every enumerated column in §5 is not null" do
      expect(StringEnumProbe.new(status: nil)).not_to be_valid
    end
  end

  describe "predicates" do
    it "answers for the current value" do
      expect(StringEnumProbe.new(status: "satisfied")).to be_satisfied
    end

    it "answers for the others" do
      expect(StringEnumProbe.new(status: "satisfied")).not_to be_pending
    end

    it "defines one per permitted value and no more" do
      probe = StringEnumProbe.new(status: "pending")

      expect(probe).to respond_to(:pending?, :satisfied?, :closed?)
      expect(probe).not_to respond_to(:rejected?)
    end
  end

  describe "scopes" do
    it "filters by value" do
      StringEnumProbe.create!(status: "pending")
      StringEnumProbe.create!(status: "closed")

      expect(StringEnumProbe.pending.count).to eq(1)
    end
  end

  # Rails' own `enum` maps values through a hash and raises at assignment on an unknown one. These
  # columns are plain, legible strings in the database, and an unknown value is a validation error.
  it "leaves the column a plain string, readable straight from the database" do
    probe = StringEnumProbe.create!(status: "closed")

    expect(probe.reload.read_attribute(:status)).to eq("closed")
  end
end
