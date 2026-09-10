# frozen_string_literal: true

module ChangeRequests
  class Configuration
    #   config.tenant_type "Organization" { |t| t.label = ->(org) { org.name } }
    #
    # Optional. The tenant columns are always created and always nullable (§5.1).
    class TenantType < RegisteredType
    end
  end
end
