# frozen_string_literal: true

module ChangeRequests
  class Configuration
    # One host class requests may be scoped to (§10):
    #
    #   config.tenant_type "Organization" do |t|
    #     t.key_type = :uuid
    #     t.label    = ->(org) { org.name }
    #   end
    #
    # Tenancy is optional. The `tenant_type` / `tenant_id` / `tenant_label` columns are always
    # created and always nullable; they stay null until a tenant type is registered (§5.1).
    class TenantType < RegisteredType
    end
  end
end
