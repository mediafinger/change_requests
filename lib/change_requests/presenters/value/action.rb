# frozen_string_literal: true

module ChangeRequests
  module Value
    # `path` is a string the caller built, or nil when no `routes:` was injected (§11).
    # `http_method`, not §11's `method`: a member named `method` shadows Object#method.
    Action = Data.define(:name, :label, :enabled, :reason, :http_method, :path, :confirm, :tone, :requires_reason) do
      def initialize(name:, enabled:, label: nil, reason: nil, http_method: :post, path: nil, confirm: nil,
                     tone: :neutral, requires_reason: false)
        super(name: name, label: label || Value.label(:actions, name), enabled: enabled, reason: reason,
              http_method: http_method, path: path, confirm: confirm, tone: Value.tone!(tone),
              requires_reason: requires_reason)
      end
    end
  end
end
