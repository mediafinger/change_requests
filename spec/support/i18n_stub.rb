# frozen_string_literal: true

# A real object, not a verified double: those cannot stand in for a constant that may be unloaded,
# and RSpec/VerifiedDoubleReference autocorrects `class_double("I18n")` into a NameError.
module I18nStub
  # Returns the recorded calls, so a spec can assert the key and the fallback that was passed.
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
