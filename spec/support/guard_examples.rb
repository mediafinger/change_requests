# frozen_string_literal: true

# Included by every guard spec. The including group supplies `guard`, a guard instance built for a
# request whose operation *is* declared; the example below takes the declaration away.
#
# One example covers both halves of §5.11 rather than skipping one of a pair, so every guard that
# includes it reports the exemption it actually has.
RSpec.shared_examples "a change request guard" do
  it "answers allowed? from reason, so a disabled button and a raised error cannot disagree (§7)" do
    expect(guard.allowed?).to eq(guard.reason.nil?)
  end

  it "refuses with a reason from the shared vocabulary, or with nothing at all (§7)" do
    expect(ChangeRequests::Guards::Base::REASONS + [nil]).to include(guard.reason)
  end

  # Every guard refuses an operation that is no longer declared, except Comment: a request stranded
  # by a removed declaration is exactly the one someone needs to leave a note on, and a comment
  # writes no lifecycle state (§5.11, I8).
  it "refuses an undeclared operation unless it is the exempt one (§5.11, I8)" do
    guard # built while the declaration still stands: a request is created against a live one

    ChangeRequests.operations.clear

    if described_class.exempt_from_undeclared_operation
      expect(guard.reason).not_to eq(:operation_undeclared)
    else
      expect(guard).not_to be_allowed
      expect(guard.reason).to eq(:operation_undeclared)

      expect { guard.check! }.to raise_error(described_class.error_class) { |error|
        expect(error.reason).to eq(:operation_undeclared)
        expect(error.request).to equal(guard.request)
      }
    end
  end
end
