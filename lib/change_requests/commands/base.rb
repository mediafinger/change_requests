# frozen_string_literal: true

module ChangeRequests
  module Commands
    # Guard, mutate, emit - inside one lock (§7).
    #
    #   class Approve < Base
    #     on_conflict NotApprovable, reason: :already_decided
    #
    #     def perform
    #       Guards::Approve.new(request:, actor:).check!
    #       ...
    #     end
    #   end
    #
    # Commands raise rather than returning a result object (§19.3), and never accept permissions
    # from the caller: they take an actor, and the gem resolves that actor's permissions through
    # their registered type (§7, §9).
    class Base
      # Which TransitionError a lost race becomes. Only a command that actually competes for a
      # unique index declares one.
      class_attribute :conflict_mapping, instance_accessor: false

      attr_reader :request, :actor, :options

      class << self
        def call(request:, actor: nil, **)
          new(request: request, actor: actor, **).call
        end

        def on_conflict(error_class, reason:)
          self.conflict_mapping = { error_class: error_class, reason: reason }
        end
      end

      def initialize(request:, actor: nil, **options)
        @request = request
        @actor   = actor
        @options = options
      end

      # SELECT … FOR UPDATE, which reloads: a command reads the row it locked, never the object it
      # was handed. Rails refuses to lock a record carrying unsaved changes, so a caller cannot lose
      # an assignment it thought it was making.
      def call
        around_perform { perform }
      rescue ActiveRecord::RecordNotUnique => e
        refuse_conflict(e)
      rescue ActiveRecord::StaleObjectError
        raise StaleRequest, "Change request #{request.id} changed while this command was running."
      end

      def perform
        fail NotImplementedError, "#{self.class.name} must implement #perform"
      end

      # Create overrides this: it has no row to lock until it has written one.
      def around_perform(&)
        request.with_lock(&)
      end

      # The single write path for events (§5.5), so the stamped columns are populated in one place.
      # M10 hangs config.on_event and ActiveSupport::Notifications here.
      def emit(kind, body: nil, metadata: {})
        request.events.create!(
          **event_actor,
          kind: kind.to_s,
          operation_version: event_operation_version,
          body: body,
          metadata: metadata,
          occurred_at: Time.current
        )
      end

      def config
        ChangeRequests.config
      end

      # Resolved live, never from the columns on the row: those are audit data (§6.12).
      def operation
        ChangeRequests.operations[request.operation_key]
      end

      private

      def event_actor
        return Event::SYSTEM_ATTRIBUTES if actor.nil?

        attributes = ChangeRequests.actor_attributes(actor)

        { actor_type: attributes[:type], actor_id: attributes[:id], actor_label: attributes[:label] }
      end

      # The version in force when this transition happened, which is deliberately not the request's
      # creation-time value. They diverge whenever a declaration changes during a request's life.
      # The fallback covers the only events ever written without a live declaration - Comment, and
      # the operation_undeclared cancellation reporting that very disappearance (§5.5, §5.11).
      def event_operation_version
        operation&.version || request.operation_version
      end

      # Never a 500 for a race the gem can lose (§15.3) - but an undeclared conflict is a bug to
      # see, not a refusal to dress it up as.
      def refuse_conflict(error)
        mapping = self.class.conflict_mapping

        fail error if mapping.nil?

        fail mapping[:error_class].new(request: request, reason: mapping[:reason])
      end
    end
  end
end
