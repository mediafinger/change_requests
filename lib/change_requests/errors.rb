# frozen_string_literal: true

module ChangeRequests
  # The error taxonomy (§7).
  #
  # The shape exists so hosts can rescue precisely rather than rescuing one base class and 500-ing on
  # everything under it: a `NotApprovable` is a flash message, a `TargetFailed` is an incident.
  # `rescue_from ChangeRequests::Error` in one place is still the fallback, and the engine controller
  # does exactly that.
  #
  # The whole tree is declared here in one pass, including the errors no milestone raises yet, so the
  # ancestry a host rescues against never changes underneath them.
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

  # Raised by `ChangeRequests.config.validate!` and by `ChangeRequests.operations.verify!`. Its
  # message names every problem found, so one boot fixes one round of mistakes.
  class ConfigurationError < Error; end

  # An actor whose class is not in the registered allowlist (§9.1). Raised before the string is ever
  # constantized, so a typo fails at creation rather than at render time (§5.7 consequence 5).
  class UnknownActorType < Error; end

  # The request's `operation_key` has no live declaration, so it can never run and every guard
  # refuses - except `Comment`, which stays open for post-mortem notes (§5.11).
  class UnknownOperation < Error; end

  # A payload that is not a JSON object. The gem validates that and nothing else: matching the
  # payload to the target's signature is the host's responsibility (§6.12).
  class InvalidPayload < Error; end

  # A creation-time fact was reassigned (§5.1). Raised by the model's own `before_update` guard
  # rather than left to `attr_readonly`, which discards the assignment in silence unless the host
  # application opted into raising.
  class ReadonlyAttribute < Error; end

  # The actor may not do this at all, as opposed to not being able to do it *yet* - that is a
  # TransitionError.
  class NotAuthorized < Error; end

  # A lifecycle transition the request will not accept: wrong status, wrong actor, wrong stage, or a
  # decision already made (§7.2).
  #
  # Every one of them carries the request it refused, the machine-readable `reason` the guard gave,
  # and a message translated from that reason:
  #
  #   fail NotApprovable.new(request:, reason: :already_decided)
  #
  # The reason is the contract - it is what a controller branches on and what a view renders as a
  # disabled button's tooltip. The message is for humans and may be translated or not.
  class TransitionError < Error
    # Guard reasons share one vocabulary and one namespace, so "the button is disabled because
    # :not_pending" and "the command refused because :not_pending" cannot drift into different
    # wording (§7). M1b-13 ships the translations.
    I18N_SCOPE = "change_requests.errors"

    attr_reader :request, :reason

    def initialize(message = nil, request: nil, reason: nil)
      @request = request
      @reason  = reason

      super(message || translated_message)
    end

    # `change_requests.errors.already_decided`, falling back to the untranslated symbol so a headless
    # caller still gets something legible (§15.5).
    def i18n_key = "#{I18N_SCOPE}.#{reason || self.class.error_key}"

    # `NotApprovable` => "not_approvable". The class's own name, used when a caller raised without a
    # reason - `fail NotApprovable` is still valid, it just says less.
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

  # The target raised. The original is preserved as `#cause`, since this is always raised from inside
  # the rescue that caught it - the class, the message and the backtrace are also recorded on the
  # attempt row and in the `execution_failed` event (§5.6, §8).
  class TargetFailed < ExecutionError; end

  # The retry ceiling is spent: `attempts.count` has reached `max_attempts` (§8).
  class AttemptsExhausted < ExecutionError; end

  # Another process claimed this request first. The conditional UPDATE in T1 updated zero rows, which
  # is the double-execution fix doing its job - do not invoke the target (§8).
  class ExecutionInProgress < ExecutionError; end

  # Optimistic lock conflict: the request changed under a command that had already read it.
  class StaleRequest < Error; end
end
