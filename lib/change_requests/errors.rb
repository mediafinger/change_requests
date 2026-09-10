# frozen_string_literal: true

module ChangeRequests
  # §7's taxonomy, declared in full including errors no milestone raises yet: the ancestry a host
  # rescues against must not change under them.
  #
  #   ChangeRequests::Error
  #   ├── ConfigurationError            (no actor types registered, invalid operation)
  #   ├── UnknownActorType              (an actor whose class is not registered)
  #   ├── UnknownOperation              (no live declaration for the request's operation_key)
  #   ├── InvalidPayload                (payload is not a JSON object)
  #   ├── ReadonlyAttribute             (a creation-time fact was reassigned; §5.1)
  #   ├── NotAuthorized
  #   ├── TransitionError
  #   │   ├── NotApprovable  ├── NotUnapprovable  ├── NotRejectable
  #   │   ├── NotExecutable  ├── NotCancelable    ├── AlreadyFinalized
  #   │   ├── QuorumNotMet   └── OverrideNotPermitted
  #   ├── ExecutionError
  #   │   ├── TargetFailed              (wraps the original; #cause preserved)
  #   │   ├── AttemptsExhausted
  #   │   └── ExecutionInProgress
  #   └── StaleRequest                  (optimistic lock conflict)
  class Error < StandardError; end

  # Raised by config.validate! and operations.verify!. Message lists every problem found at once.
  class ConfigurationError < Error; end

  # Raised before the type string is constantized, so a typo fails at creation, not at render time.
  class UnknownActorType < Error; end

  # No live declaration for the request's operation_key. Every guard refuses except Comment (§5.11).
  class UnknownOperation < Error; end

  # Payload is not a JSON object. Matching it to the target's signature is the host's job (§6.12).
  class InvalidPayload < Error; end

  # A creation-time fact was reassigned. Raised by Concerns::ReadonlyAttributes, not attr_readonly.
  class ReadonlyAttribute < Error; end

  # The actor may never do this. "Not yet" is a TransitionError.
  class NotAuthorized < Error; end

  # A transition the request will not accept (§7.2). Carries #request and #reason:
  #
  #   fail NotApprovable.new(request:, reason: :already_decided)
  #
  # `reason` is the contract - controllers branch on it, views render it as a disabled button's
  # tooltip. The message is for humans.
  class TransitionError < Error
    # Shared with the guards, so a disabled button and a raised error cannot word :not_pending
    # differently. M1b-13 ships the translations.
    I18N_SCOPE = "change_requests.errors"

    attr_reader :request, :reason

    def initialize(message = nil, request: nil, reason: nil)
      @request = request
      @reason  = reason

      super(message || translated_message)
    end

    def i18n_key = "#{I18N_SCOPE}.#{reason || self.class.error_key}"

    # NotApprovable => "not_approvable". Used when a caller raised without a reason.
    def self.error_key
      name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    private

    def translated_message
      fallback = (reason || self.class.error_key).to_s

      Translation.translate(i18n_key, default: fallback)
    end
  end

  class NotApprovable < TransitionError; end
  class NotUnapprovable < TransitionError; end
  class NotRejectable < TransitionError; end
  class NotExecutable < TransitionError; end
  class NotCancelable < TransitionError; end
  class AlreadyFinalized < TransitionError; end
  class QuorumNotMet < TransitionError; end
  class OverrideNotPermitted < TransitionError; end

  # Something went wrong while running the target, as opposed to something refusing to let it run.
  class ExecutionError < Error; end

  # The target raised. Always raised from inside the rescue that caught it, so #cause is preserved.
  class TargetFailed < ExecutionError; end

  # The retry ceiling is spent: `attempts.count` has reached `max_attempts` (§8).
  class AttemptsExhausted < ExecutionError; end

  # T1's conditional UPDATE hit zero rows: another process holds the claim. Do not invoke the target.
  class ExecutionInProgress < ExecutionError; end

  # Optimistic lock conflict: the request changed under a command that had already read it.
  class StaleRequest < Error; end
end
