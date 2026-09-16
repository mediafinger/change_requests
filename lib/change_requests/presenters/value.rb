# frozen_string_literal: true

module ChangeRequests
  # What every presenter method returns (§11). Plain `Data`, so a spec compares a whole structure in
  # one expectation, and no ActionView, so a job or an API controller reads them as well as a view.
  module Value
    # Closed. M6's CSS classes and M5-7's as_json both enumerate it.
    TONES = %i(neutral primary success warning danger).freeze

    module_function

    def tone!(tone)
      symbol = tone.to_s.to_sym if tone.respond_to?(:to_sym)

      return symbol if TONES.include?(symbol)

      fail ArgumentError, "tone #{tone.inspect} is not one of #{TONES.join(", ")}"
    end

    # The §5.9 mechanism: a locale entry if the host wrote one, the humanized identifier otherwise.
    def label(namespace, key)
      Translation.translate("change_requests.#{namespace}.#{key}", default: key.to_s.humanize)
    end
  end
end
