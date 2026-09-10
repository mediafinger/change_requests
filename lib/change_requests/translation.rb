# frozen_string_literal: true

module ChangeRequests
  # Every lookup passes a usable default: most keys have no translation until M1b-13 ships the
  # locale file. Also used for stage and quorum display names (§5.9).
  #
  # `available?` is defensive only - ActiveSupport pulls in i18n, so it is true in any process that
  # loaded the gem.
  module Translation
    module_function

    def translate(key, default:)
      return default unless available?

      I18n.translate(key, default: default)
    end

    def available? = defined?(I18n) ? true : false
  end
end
