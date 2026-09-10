# frozen_string_literal: true

RSpec.describe ChangeRequests::Error do
  # The ancestry is the contract: a host writes `rescue ChangeRequests::TransitionError` once and
  # expects every refusal to land there. Moving a class between branches is a breaking change, so
  # every edge of §7's tree is asserted rather than assumed. Names, not constants, so the table reads
  # like the tree in the documentation.
  def self.taxonomy
    {
      "ConfigurationError"   => "Error",
      "UnknownActorType"     => "Error",
      "UnknownOperation"     => "Error",
      "InvalidPayload"       => "Error",
      "ReadonlyAttribute"    => "Error",
      "NotAuthorized"        => "Error",
      "TransitionError"      => "Error",
      "NotApprovable"        => "TransitionError",
      "NotUnapprovable"      => "TransitionError",
      "NotRejectable"        => "TransitionError",
      "NotExecutable"        => "TransitionError",
      "NotCancelable"        => "TransitionError",
      "AlreadyFinalized"     => "TransitionError",
      "QuorumNotMet"         => "TransitionError",
      "OverrideNotPermitted" => "TransitionError",
      "ExecutionError"       => "Error",
      "TargetFailed"         => "ExecutionError",
      "AttemptsExhausted"    => "ExecutionError",
      "ExecutionInProgress"  => "ExecutionError",
      "StaleRequest"         => "Error",
    }.freeze
  end

  describe "the taxonomy" do
    it "is rooted in StandardError, so a bare `rescue => e` catches it" do
      expect(described_class.superclass).to eq(StandardError)
    end

    taxonomy.each do |name, superclass|
      it "defines #{name} under #{superclass}" do
        expect(ChangeRequests.const_get(name).superclass).to eq(ChangeRequests.const_get(superclass))
      end
    end

    it "puts every error under one root, so a single rescue_from covers the gem" do
      errors = self.class.taxonomy.keys.map { |name| ChangeRequests.const_get(name) }

      expect(errors).to all(be < described_class)
    end

    # Declaring the whole tree in one pass means the ancestry a host rescues against never changes
    # underneath them, even for errors no milestone raises yet.
    it "declares the whole tree and nothing beyond it" do
      declared = ChangeRequests.constants.filter_map do |name|
        value = ChangeRequests.const_get(name)

        name.to_s if value.is_a?(Class) && value < described_class
      end

      expect(declared).to match_array(self.class.taxonomy.keys)
    end
  end

  describe ChangeRequests::TransitionError do
    subject(:error) { described_class.new(request: request, reason: :already_decided) }

    let(:request) { Object.new }

    it "carries the request it refused" do
      expect(error.request).to equal(request)
    end

    it "carries the machine-readable reason a controller branches on" do
      expect(error.reason).to eq(:already_decided)
    end

    it "namespaces the reason under one i18n scope, shared with the guards" do
      expect(error.i18n_key).to eq("change_requests.errors.already_decided")
    end

    # §15.5: the domain core runs with no Rails, no engine and no locale files.
    it "falls back to the reason itself when nothing translates it" do
      expect(error.message).to eq("already_decided")
    end

    it "translates the reason when I18n is available" do
      with_i18n(returning: "You have already decided this stage")

      expect(described_class.new(reason: :already_decided).message)
        .to eq("You have already decided this stage")
    end

    it "hands I18n the untranslated fallback, so a missing key is never a raised exception" do
      calls = with_i18n

      described_class.new(reason: :already_decided).message

      expect(calls).to eq([{ key: "change_requests.errors.already_decided",
                             options: { default: "already_decided" } }])
    end

    it "accepts an explicit message, which wins over any translation" do
      expect(described_class.new("Bob already decided", reason: :already_decided).message)
        .to eq("Bob already decided")
    end

    context "when raised without a reason" do
      subject(:error) { ChangeRequests::NotApprovable.new }

      it "still produces a message, naming itself" do
        expect(error.message).to eq("not_approvable")
      end

      it "keys off its own class name" do
        expect(error.i18n_key).to eq("change_requests.errors.not_approvable")
      end

      it "reports no request and no reason rather than inventing them" do
        expect(error.request).to be_nil
        expect(error.reason).to be_nil
      end
    end

    it "is raisable with the bare class, like any StandardError" do
      expect { fail ChangeRequests::NotCancelable }
        .to raise_error(ChangeRequests::NotCancelable, "not_cancelable")
    end

    it "is raisable with a message, like any StandardError" do
      expect { fail ChangeRequests::NotCancelable, "nope" }
        .to raise_error(ChangeRequests::NotCancelable, "nope")
    end
  end

  describe ChangeRequests::TargetFailed do
    # The original is never wrapped by hand: TargetFailed is raised from inside the rescue that
    # caught it, so Ruby preserves it for free (§7, §8 T3).
    it "preserves the original failure as #cause" do
      raised = capture_target_failure

      expect(raised.cause).to be_a(ArgumentError)
      expect(raised.cause.message).to eq("unknown keyword: :roles")
    end

    def capture_target_failure
      begin
        fail ArgumentError, "unknown keyword: :roles"
      rescue ArgumentError
        raise described_class, "Members::UpdateRoles.call failed"
      end
    rescue described_class => e
      e
    end
  end
end
