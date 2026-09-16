# frozen_string_literal: true

module ChangeRequests
  # What a view, an API controller or a job renders a request from (§11).
  #
  #   p = RequestPresenter.new(request, actor: current_user, routes: view, resolve_actors: true)
  #
  # No ActionView: `routes` is an optional url-helper object handed to `ActorRef#path`, and nothing here
  # reads the operation registry, so an undeclared operation renders like any other (§5.12).
  class RequestPresenter
    # Closed, and read by M6's CSS and M5-7's as_json. A spec holds it to Request::STATUSES.
    STATUS_TONES = {
      pending: :neutral,
      approved: :primary,
      executing: :primary,
      successful: :success,
      failed: :danger,
      rejected: :danger,
      canceled: :neutral,
      expired: :warning,
    }.freeze

    CANCELING_KINDS = %w(canceled operation_undeclared).freeze

    attr_reader :request, :actor, :routes

    def initialize(request, actor:, routes: nil, resolve_actors: true)
      @request        = request
      @actor          = actor
      @routes         = routes
      @resolve_actors = resolve_actors
    end

    def resolve_actors?
      @resolve_actors
    end

    def operation_key
      request.operation_key
    end

    def operation_version
      request.operation_version
    end

    def operation_label
      "#{request.service}.#{request.method_name}"
    end

    def requester
      actors[:requester]
    end

    def executer
      actors[:executer]
    end

    def tenant
      actors[:tenant]
    end

    # Alphabetical by key: jsonb keeps no insertion order (§5.12). A declared label replaces the raw
    # value; a missing one is the normal case.
    def payload_fields
      @payload_fields ||= begin
        labels = request.payload_labels || {}

        (request.payload || {}).sort_by { |key, _| key.to_s }.map do |key, raw|
          Value::Field.new(key: key, value: labels.fetch(key.to_s, raw))
        end
      end
    end

    def payload_preview
      payload_fields.first(ChangeRequests.config.payload_preview_limit)
    end

    def status
      @status ||= begin
        key = request.status.to_sym

        Value::Status.new(key: key, tone: status_tone(key), tooltip: status_tooltip(key))
      end
    end

    private

    # Resolved together on first read: one query per actor type across all three, then none.
    def actors
      @actors ||= begin
        refs = { requester: request.requester, executer: request.executer, tenant: request.tenant }

        if resolve_actors?
          ActorResolver.call(refs.values.compact)
          refs
        else
          refs.transform_values { |ref| ref&.without_resolution }
        end
      end
    end

    # §8.1: a request that ran without its approvals says so, unless the run failed.
    def status_tone(key)
      return :warning if request.overridden_at.present? && key != :failed

      STATUS_TONES.fetch(key)
    end

    def status_tooltip(key)
      case key
      when :failed   then latest_failed_attempt&.error_message
      when :canceled then latest_event(CANCELING_KINDS)&.body
      when :expired  then expired_tooltip
      else overridden_tooltip
      end
    end

    def expired_tooltip
      return if request.expires_at.nil?

      Translation.translate("change_requests.statuses.expired_tooltip", default: "Expired at %{expires_at}",
                                                                        expires_at: request.expires_at.utc.iso8601)
    end

    def overridden_tooltip
      return if request.overridden_at.nil?

      event = latest_event(%w(overridden))

      return if event.nil?

      Translation.translate("change_requests.statuses.overridden_tooltip",
                            default: "Executed without approval: %{present} of %{required} approvals. " \
                                     "Reason: %{reason}",
                            present: event.metadata["approvals_present"],
                            required: event.metadata["approvals_required"],
                            reason: event.body)
    end

    # Through the association rather than a query of its own, so a preloaded request costs nothing.
    def latest_event(kinds)
      request.events.to_a.rfind { |event| kinds.include?(event.kind) }
    end

    def latest_failed_attempt
      request.attempts.to_a.rfind { |attempt| attempt.outcome == "failed" }
    end
  end
end
