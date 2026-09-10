# frozen_string_literal: true

# The gem never requires I18n - the domain core has to produce messages headless, with no Rails and
# no locale files (§1, §15.5) - so `I18n` is genuinely undefined in this suite. A verified double
# cannot stand in for a constant that was never loaded, so this is a real object that records what it
# was asked to translate.
module I18nStub
  # Returns the recorded calls, so a spec can assert the key *and* the fallback that was passed.
  def with_i18n(returning: "translated")
    calls = []

    fake = Module.new
    fake.define_singleton_method(:translate) do |key, **options|
      calls << { key: key, options: options }
      returning
    end

    stub_const("I18n", fake)

    calls
  end
end

RSpec.configure do |config|
  config.include I18nStub
end
