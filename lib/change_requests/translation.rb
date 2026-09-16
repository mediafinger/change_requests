# frozen_string_literal: true

module ChangeRequests
  # Every lookup passes a usable default: most keys have no translation until M1b-13 ships the
  # locale file. Also used for stage and quorum display names (§5.9).
  #
  # `available?` is defensive only - ActiveSupport pulls in i18n, so it is true in any process that
  # loaded the gem.
  module Translation
    module_function

    # `values` interpolate `%{name}` references, into the default too when there is no I18n.
    def translate(key, default:, **values)
      return I18n.translate(key, default: default, **values) if available?

      # `format` would read a bare "%" in an untranslated message as a broken directive.
      values.empty? ? default : format(default, **values)
    end

    def available?
      defined?(I18n) ? true : false
    end
  end
end
