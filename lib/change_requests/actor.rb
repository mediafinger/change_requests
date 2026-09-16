# frozen_string_literal: true

module ChangeRequests
  # An optional convenience for a host's actor model (§9):
  #
  #   class User < ApplicationRecord
  #     include ChangeRequests::Actor
  #   end
  #
  #   user.change_requests               # the ones they raised
  #   user.change_requests_visible       # what they may see (§9.3)
  #   user.may_request_change_requests?  # what their registered type declares
  #
  # **Read-side conveniences only, and it registers nothing.** Registration is
  # `config.actor_type`, and putting the same fact in two places is how the two drift. Every method
  # here is a thin delegation to a scope or to the registry, so a host that never includes it can
  # write the same line themselves - which is also why nothing inside the gem requires it.
  #
  # `change_requests_awaiting_approval` arrives with M9c, which owns `awaiting_approval_from`. It
  # is named here so it is not invented twice.
  module Actor
    def change_requests
      Request.requested_by(self)
    end

    def change_requests_visible
      Request.visible_to(self)
    end

    # Which *actions* a given person may trigger is the host's own authorization question, answered
    # before `ChangeRequests.request!` is called. This answers only which **classes** may raise a
    # request at all (§19.4).
    def may_request_change_requests?
      ChangeRequests.registered_type!(self).may_request
    end
  end
end
