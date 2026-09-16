# frozen_string_literal: true

module ChangeRequests
  class Configuration
    #   config.actor_type "User" do |t|
    #     t.key_type    = :uuid
    #     t.label       = ->(user) { user.full_name.presence || user.email }
    #     t.permissions = ->(user) { user.roles }
    #   end
    #
    # `name` is the full constant name, verbatim - "Accounts::Admin", and the subclass's own name
    # under STI, since two STI subclasses may need different labels, permissions and key casts.
    #
    # `finder` arrives with M4-2.
    class ActorType < RegisteredType
      # `path` is the optional deep link a view renders an actor as (§9.1, §12):
      #
      #   t.path = ->(user, routes) { routes.admin_user_path(user) }
      #
      # Nil by default, and never required: a headless caller has no url helpers to pass, and
      # `ActorRef#path` answers nil rather than guessing.
      attr_accessor :permissions, :path, :may_request, :may_approve, :may_execute

      def initialize(name)
        super

        @permissions = nil
        @path        = nil
        @may_request = true
        @may_approve = true
        @may_execute = true
      end

      def problems
        super + [permissions_problem].compact
      end

      private

      # Only approvers need one: a class that may request but not approve never has it read.
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
