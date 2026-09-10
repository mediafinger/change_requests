# frozen_string_literal: true

require "rails_helper"

ProbeTable.create!(:readonly_probes)

class ReadonlyProbe < ChangeRequests::Record
  self.table_name = "readonly_probes"

  include ChangeRequests::Concerns::ReadonlyAttributes

  readonly_after_create :operation_key, :payload
end

RSpec.describe ChangeRequests::Concerns::ReadonlyAttributes do
  subject(:probe) { ReadonlyProbe.create!(operation_key: "members.update_roles", label: "before") }

  it "records what was declared" do
    expect(ReadonlyProbe.readonly_after_create_attributes).to eq(%w(operation_key payload))
  end

  it "sets the values at creation without complaint" do
    expect(probe.operation_key).to eq("members.update_roles")
  end

  it "leaves undeclared attributes writable" do
    probe.update!(label: "after")

    expect(probe.reload.label).to eq("after")
  end

  describe "changing a declared attribute" do
    # The whole point of the list is that a snapshot cannot drift, so the one outcome it must not
    # have is silence - which is what Rails' `attr_readonly` gives unless the *host application* has
    # `raise_on_assign_to_attr_readonly` enabled (issue I4).
    it "raises rather than discarding the change quietly" do
      probe.operation_key = "something.else"

      expect { probe.save! }.to raise_error(ChangeRequests::ReadonlyAttribute)
    end

    it "names the attribute, so the failure says which one" do
      probe.operation_key = "something.else"

      expect { probe.save! }.to raise_error(/ReadonlyProbe#operation_key/)
    end

    it "leaves the stored value untouched" do
      probe.operation_key = "something.else"
      suppress(ChangeRequests::ReadonlyAttribute) { probe.save }

      expect(probe.reload.operation_key).to eq("members.update_roles")
    end

    it "catches a jsonb column too, which changes by mutation as easily as by assignment" do
      probe.payload = { "member_id" => 7 }

      expect { probe.save! }.to raise_error(ChangeRequests::ReadonlyAttribute)
    end

    it "reports every changed attribute at once" do
      probe.operation_key = "something.else"
      probe.payload = { "member_id" => 7 }

      expect { probe.save! }.to raise_error(/operation_key, #payload/)
    end
  end

  it "raises the gem's own error, so a host rescues one taxonomy rather than two" do
    probe.operation_key = "something.else"

    expect { probe.save! }.to raise_error(ChangeRequests::Error)
  end

  # `update_columns` bypasses callbacks by design. Documented rather than defended: it is nobody's
  # accident, and the alternative is pretending a gem can lock a database it does not own.
  it "does not defend against update_columns, which bypasses callbacks on purpose" do
    expect { probe.update_columns(operation_key: "bypassed") }.not_to raise_error
  end
end
