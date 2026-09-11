# frozen_string_literal: true

module ChangeRequests
  module Guards
    # May this request be expired right now (§7.2, §8)?
    #
    # System only. Expiry has no human behind it, so an actor being supplied at all is the refusal -
    # nobody expires a request on purpose, the clock does.
    #
    # Every refusal here is NotAuthorized rather than a TransitionError, apart from the shared
    # :already_finalized mapping. The only caller is M3b's `Maintenance.expire_stale!`, whose query
    # already filters on status and `expires_at`, so these branches are a floor beneath it and never
    # a user-facing flash (Q32).
    class Expire < Base
      EXPIRABLE_STATUSES = %w(pending approved).freeze

      refuses_with NotAuthorized

      def refusal
        return :not_system unless actor.nil?
        return :already_finalized if request.final?
        return :not_expirable unless EXPIRABLE_STATUSES.include?(request.status)
        return :not_expired unless expired?

        nil
      end

      private

      # A null `expires_at` never expires (§5.1), which is the default: `config.default_expires_in`
      # and `op.expires_in` are both nil until a host says otherwise.
      def expired?
        request.expires_at.present? && request.expires_at <= Time.current
      end
    end
  end
end
