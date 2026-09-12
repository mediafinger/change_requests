# frozen_string_literal: true

module ChangeRequests
  class Operation
    # §8.1's break-glass declaration: who may take it, and whether they must say why.
    #
    #   op.override permissions: %w(security_officer), require_reason: true
    #
    # An empty permission list is a declaration, not an oversight: the override is then open to any
    # actor whose registered type `may_execute`. §8.1 calls the override separately permissioned,
    # and a host declaring none has said that its execute permission is the separation.
    Override = Data.define(:permissions, :require_reason) do
      def require_reason?
        require_reason
      end

      def unrestricted?
        permissions.empty?
      end
    end
  end
end
