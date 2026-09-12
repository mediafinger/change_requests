# frozen_string_literal: true

module ChangeRequests
  module Commands
    # Records the intent instead of running it, and freezes the approval policy onto the row (§7.2).
    #
    #   Commands::Create.call(
    #     operation_key: "members.update_roles",
    #     payload:       { member_id: 42, roles: %w(editor) },
    #     requester:     current_admin,
    #     tenant:        current_organization      # optional
    #   )
    #
    # `ChangeRequests.request!` is the host-facing wrapper (§6.5); this is the command itself.
    #
    # The call is identical however elaborate the workflow is: thresholds, permissions and quorum
    # structure come from the declaration, never from the caller (§6.12 point 3).
    class Create < Base
      attr_reader :operation_key, :requester, :payload, :tenant

      def self.call(operation_key:, requester:, payload: {}, tenant: nil)
        new(operation_key: operation_key, requester: requester, payload: payload, tenant: tenant).call
      end

      def initialize(operation_key:, requester:, payload: {}, tenant: nil)
        super(request: nil, actor: requester)

        @operation_key = operation_key.to_s
        @requester     = requester
        @payload       = payload
        @tenant        = tenant
      end

      # Base's helper resolves the operation from the request, which does not exist yet.
      def operation
        ChangeRequests.operations[operation_key]
      end

      def perform
        declaration = usable_operation
        refuse_unless_may_request

        @request = write_request(declaration)
        materialise(declaration.workflow)
        emit(:requested)

        request
      end

      private

      # The whole graph, or none of it.
      def around_perform(&)
        Record.transaction(&)
      end

      def usable_operation
        declaration = operation

        fail UnknownOperation, "No operation is declared for #{operation_key.inspect} (§5.11)." if declaration.nil?

        refuse_incomplete(declaration)

        declaration
      end

      # The same `Operation#problems` that `verify!` reads at boot and `validate!` reads at
      # declaration, so the three cannot disagree about what a complete declaration is (§7.2 †).
      # This is the backstop: an operation mutated after it was declared still refuses here.
      def refuse_incomplete(declaration)
        problems = declaration.problems

        return if problems.empty?

        fail ConfigurationError,
             "Operation #{operation_key.inspect} cannot be requested (§6.4):\n- #{problems.join("\n- ")}"
      end

      # Which actions a given person may trigger is the host's own authorization question, answered
      # before this call. The registry answers only which *classes* may raise a request (§19.4).
      def refuse_unless_may_request
        type = ChangeRequests.config.actor_types[requester.class.name]

        # Unregistered classes are the allowlist's business, and actor_attributes raises for them.
        return if type.nil? || type.may_request

        # No message: the reason carries it, so the text comes from the host's locale file and says
        # nothing about `t.may_request` - a configuration key has no business in a flash (Q45).
        fail NotAuthorized.new(reason: :may_not_request)
      end

      def write_request(declaration)
        Request.create!(
          operation_key: declaration.key,
          operation_version: declaration.version,
          service: declaration.service,
          method_name: declaration.method_name.to_s,
          payload: validated_payload,
          payload_labels: labels,
          requester: requester,
          tenant: tenant,
          max_attempts: declaration.max_attempts,
          expires_at: expires_at(declaration)
        )
      end

      # The gem validates only that it is a JSON object; matching it to the target's signature is
      # the host's responsibility (§6.12).
      def validated_payload
        return payload if payload.is_a?(Hash)

        fail InvalidPayload,
             "payload must be a JSON object, got #{payload.class}. It is dispatched as " \
             "`**payload.symbolize_keys`, so its keys become the target's keyword arguments (§6.12)."
      end

      # Snapshotted so a request stays readable after the records the payload refers to are gone.
      def labels
        return {} if operation.payload_labels.nil?

        operation.payload_labels.call(validated_payload).to_h.transform_keys(&:to_s)
      end

      def expires_at(declaration)
        declaration.expires_in && (Time.current + declaration.expires_in)
      end

      # The frozen snapshot: editing the operation afterwards never reaches this request, and never
      # leaves it wrongly approved or wrongly pending (§6.12 point 4).
      def materialise(workflow)
        workflow.stages.each do |described_stage|
          stage = request.stages.create!(
            position: described_stage.position,
            name: described_stage.name.to_s,
            satisfied_by: described_stage.satisfied_by.to_s
          )

          described_stage.quorums.each { |described| materialise_quorum(stage, described) }
        end
      end

      def materialise_quorum(stage, described)
        quorum = stage.quorums.create!(
          position: described.position,
          name: described.name&.to_s,
          threshold: described.threshold,
          permission_match: described.permission_match.to_s
        )

        described.permissions.each do |row|
          quorum.permissions.create!(permission: row.permission, actor_type: row.actor_type)
        end

        # The declaration kept the actor objects as the host wrote them; this is where they resolve
        # to (type, id), and where an unregistered class is refused (§9.1).
        described.eligible_actors.each { |actor| quorum.eligible_actors.create!(actor: actor) }
      end
    end
  end
end
