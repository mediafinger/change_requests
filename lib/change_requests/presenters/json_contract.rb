# frozen_string_literal: true

module ChangeRequests
  # The as_json contract (§11), written out in docs/06_views_and_theming.md and pinned by a golden file.
  #
  # Ids are strings, timestamps ISO8601 UTC, enums strings, labels translated, and absent is null - never
  # omitted. Adding a key keeps SCHEMA_VERSION; removing, renaming or retyping one bumps it.
  module JsonContract
    SCHEMA_VERSION = 1

    module_function

    def request(presenter)
      request = presenter.request

      {
        "schema_version" => SCHEMA_VERSION,
        "id" => request.id.to_s,
        "operation_key" => presenter.operation_key,
        "operation_version" => presenter.operation_version,
        "operation_label" => presenter.operation_label,
        "status" => status(presenter.status),
        "requester" => actor(presenter.requester, presenter.routes),
        "executer" => actor(presenter.executer, presenter.routes),
        "tenant" => actor(presenter.tenant, presenter.routes),
        "payload" => request.payload || {},
        "payload_preview" => presenter.payload_preview.map { |field| field(field) },
        "payload_fields" => presenter.payload_fields.map { |field| field(field) },
        "stages" => presenter.stages.map { |stage| stage(stage) },
        "actions" => presenter.actions.map { |action| action(action) },
        "timeline" => presenter.timeline.map { |entry| timeline_entry(entry, presenter.routes) },
        "created_at" => time(request.created_at),
        "expires_at" => time(request.expires_at),
        "executed_at" => time(request.executed_at),
        "overridden_at" => time(request.overridden_at),
        "attempts" => request.attempts.size,
        "max_attempts" => request.max_attempts,
        "retryable" => request.attempts.size < request.max_attempts,
      }
    end

    def status(status)
      { "key" => status.key.to_s, "label" => status.label, "tone" => status.tone.to_s, "tooltip" => status.tooltip }
    end

    def actor(ref, routes)
      return if ref.nil?

      { "type" => ref.type, "id" => ref.id, "label" => ref.label, "deleted" => ref.deleted?,
        "path" => ref.path(routes) }
    end

    def field(field)
      { "key" => field.key.to_s, "label" => field.label, "value" => field.value }
    end

    def stage(stage)
      {
        "name" => stage.name.to_s, "label" => stage.label, "position" => stage.position,
        "status" => stage.status.to_s, "satisfied" => stage.satisfied?, "current" => stage.current?,
        "satisfied_by" => stage.satisfied_by.to_s, "satisfied_via" => stage.satisfied_via,
        "remaining_options" => stage.remaining_options.to_a, "quorums" => stage.quorums.map { |quorum| quorum(quorum) }
      }
    end

    def quorum(quorum)
      { "name" => quorum.name, "label" => quorum.label, "required" => quorum.required,
        "approved" => quorum.approved, "satisfied" => quorum.satisfied?, "approvers" => quorum.approvers.to_a }
    end

    # `method` in JSON, `http_method` in Ruby: a Data member named `method` shadows Object#method (M5-1).
    def action(action)
      {
        "name" => action.name.to_s, "label" => action.label, "enabled" => action.enabled, "reason" => action.reason,
        "method" => action.http_method.to_s, "path" => action.path, "confirm" => action.confirm,
        "tone" => action.tone.to_s, "requires_reason" => action.requires_reason
      }
    end

    def timeline_entry(entry, routes)
      {
        "kind" => entry.kind.to_s, "label" => entry.label, "body" => entry.body, "detail" => entry.detail,
        "actor" => actor(entry.actor, routes), "metadata" => entry.metadata.to_h,
        "occurred_at" => time(entry.occurred_at), "operation_version" => entry.operation_version
      }
    end

    def time(value)
      value&.utc&.iso8601
    end
  end
end
