# frozen_string_literal: true

module ChangeRequests
  # Translation without a hard dependency on I18n.
  #
  # The domain core has to produce a message with no Rails, no engine and no locale files loaded
  # (§1, §15.5), so every lookup passes a usable default and I18n is consulted only when it is
  # actually there. A host that has it - every Rails host does - gets translated text; a rake task or
  # a bare ActiveRecord connection gets the fallback.
  #
  # Also used for stage and quorum display names (§5.9) and guard reasons (M1b-13), which are the
  # same problem: a key that may or may not be translated, and a sensible thing to show when it is
  # not.
  module Translation
    module_function

    def translate(key, default:)
      return default unless available?

      I18n.translate(key, default: default)
    end

    def available? = defined?(I18n) ? true : false
  end
end
