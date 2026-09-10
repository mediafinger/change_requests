# frozen_string_literal: true

module ChangeRequests
  class Configuration
    # One host class that may act on change requests (§9.1):
    #
    #   config.actor_type "User" do |t|
    #     t.key_type    = :uuid
    #     t.label       = ->(user) { user.full_name.presence || user.email }
    #     t.permissions = ->(user) { user.permissions }
    #     t.may_request = true
    #     t.may_approve = true
    #     t.may_execute = true
    #   end
    #
    # `name` is the actor's full constant name, verbatim: "Admin" for a top-level class,
    # "Accounts::Admin" for a namespaced one, and the subclass's own name under STI - two STI
    # subclasses may need different labels, permissions and key casts, so neither collapses into a
    # base class.
    #
    # `finder` and `path` arrive in M4, with `ActorRef` and batch resolution.
    class ActorType < RegisteredType
      attr_accessor :permissions, :may_request, :may_approve, :may_execute

      def initialize(name)
        super

        @permissions = nil
        @may_request = true
        @may_approve = true
        @may_execute = true
      end

      def problems
        super + [permissions_problem].compact
      end

      private

      # Only approvers need a permission set: eligibility is matched against the quorum's permission
      # rows (§5.3). A class that may request but not approve never has its permissions read.
      def permissions_problem
        return unless may_approve
        return if permissions.respond_to?(:call)

        "#{describe} may approve but has no permissions, for example " \
          "`t.permissions = ->(user) { user.roles }`. Approval eligibility is matched against " \
          "this set (§5.3). Set `t.may_approve = false` if the class is not meant to approve."
      end
    end
  end
end
