# frozen_string_literal: true

RSpec.describe ChangeRequests::Error do
  # The ancestry is the contract: moving a class between branches breaks a host's rescue.
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

    # §15.5: the domain core runs with no Rails, no engine and no locale files. The reason here is
    # deliberately one the gem does not ship a translation for - config/locales/en.yml reaches
    # I18n.load_path as soon as any spec boots the dummy app, and a claim about the fallback must
    # not depend on which files ran first.
    it "falls back to the reason itself when nothing translates it" do
      expect(described_class.new(reason: :nothing_translates_this).message)
        .to eq("nothing_translates_this")
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
        expect(error.message).to eq(I18n.t("change_requests.errors.not_approvable",
                                           default: "not_approvable"))
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
        .to raise_error(ChangeRequests::NotCancelable,
                        I18n.t("change_requests.errors.not_cancelable", default: "not_cancelable"))
    end

    it "is raisable with a message, like any StandardError" do
      expect { fail ChangeRequests::NotCancelable, "nope" }
        .to raise_error(ChangeRequests::NotCancelable, "nope")
    end
  end

  # Regression: Guards::Base#check! builds whichever class a guard declared with request: and
  # reason:, and NotAuthorized was a plain Error. Ruby folds keywords into the message for a method
  # that takes none, so it silently produced message "{request: …, reason: …}" and no readers at
  # all - losing the symbol hosts branch on. Comment is the first guard to declare it.
  describe ChangeRequests::NotAuthorized do
    subject(:error) { described_class.new(request: :a_request, reason: :not_permitted) }

    it "carries the request" do
      expect(error.request).to eq(:a_request)
    end

    it "carries the reason, which is the contract hosts branch on" do
      expect(error.reason).to eq(:not_permitted)
    end

    it "words its message from the reason, not from the keywords it was handed" do
      expect(described_class.new(request: :a_request, reason: :nothing_translates_this).message)
        .to eq("nothing_translates_this")
    end

    it "still accepts a plain message, which Commands::Create raises it with" do
      expect(described_class.new("Admin may not raise change requests").message)
        .to eq("Admin may not raise change requests")
    end

    # §8 keeps them apart: "the actor may never do this" is a different answer from "not yet", and
    # a host rescues them separately.
    it "is a sibling of the TransitionError family, not a member of it" do
      expect(described_class.ancestors).not_to include(ChangeRequests::TransitionError)
      expect(described_class.ancestors).to include(ChangeRequests::Error)
    end
  end

  # One module, included by both, so the two cannot drift.
  describe ChangeRequests::Refusal do
    it "is what gives a refusal its request, reason and translated message" do
      expect(ChangeRequests::TransitionError.ancestors).to include(described_class)
      expect(ChangeRequests::NotAuthorized.ancestors).to include(described_class)
    end

    it "is included by every class Guards::Base can be told to raise" do
      declared = [ChangeRequests::NotApprovable, ChangeRequests::NotUnapprovable,
                  ChangeRequests::NotRejectable, ChangeRequests::NotCancelable,
                  ChangeRequests::NotExecutable, ChangeRequests::AlreadyFinalized,
                  ChangeRequests::NotAuthorized]

      expect(declared.reject { |klass| klass.ancestors.include?(described_class) }).to be_empty
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
