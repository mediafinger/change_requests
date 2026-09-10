# frozen_string_literal: true

module ChangeRequests
  # The base of the taxonomy. Hosts rescue precisely rather than rescuing this and 500-ing on the
  # rest (§7).
  #
  # M0-4 fills in the remainder of the tree - UnknownActorType, UnknownOperation, InvalidPayload,
  # ReadonlyAttribute, NotAuthorized, the TransitionError and ExecutionError families, StaleRequest.
  # Only the errors M0-3 actually raises are defined here.
  class Error < StandardError; end

  # Raised by `ChangeRequests.config.validate!`, and by the setters of settings that are hard-wired
  # (§8, §19.14). Its message names every problem found, so one boot fixes one round of mistakes.
  class ConfigurationError < Error; end
end
