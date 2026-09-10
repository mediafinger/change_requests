# frozen_string_literal: true

# Stores real translations for the duration of one example. Takes dotted keys, since that is how
# §5.9's label keys are written.
module Translations
  def with_translations(flat)
    @translations_stored = true

    flat.each do |key, value|
      nested = key.to_s.split(".").reverse.reduce(value) { |memo, part| { part.to_sym => memo } }

      I18n.backend.store_translations(:en, nested)
    end
  end
end

RSpec.configure do |config|
  config.include Translations

  # Only where this helper ran: other examples stub I18n with a fake that has no backend.
  config.after { I18n.backend.reload! if @translations_stored }
end
