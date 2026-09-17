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

    # One per transition a host can offer, in display order (§7, §8.1). `route` is the member path the
    # engine draws; an override posts to Execute's.
    ACTIONS = {
      approve: { guard: Guards::Approve, tone: :primary },
      unapprove: { guard: Guards::Unapprove, tone: :neutral },
      reject: { guard: Guards::Reject, tone: :danger, requires_reason: true },
      execute: { guard: Guards::Execute, tone: :primary },
      execute_override: { guard: Guards::Execute, options: { override: true }, tone: :danger, route: :execute },
      cancel: { guard: Guards::Cancel, tone: :warning, requires_reason: true },
      comment: { guard: Guards::Comment, tone: :neutral },
    }.freeze

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

    # §11, §7.1. One per stage in position order. `approved` counts the approval_quorums links, so an
    # all_quorums stage never shows as met by fewer distinct people than it needs.
    def stages
      @stages ||= begin
        preload_progress

        request.stages.sort_by(&:position).map { |stage| stage_progress(stage) }
      end
    end

    # §11, §5.5. One entry per event row in `occurred_at` order, the actors resolved together - or not at
    # all with resolve_actors: false. System entries need no branch: the sentinel is never deleted.
    def timeline
      @timeline ||= begin
        events = request.events.to_a
        refs = events.map(&:actor)

        resolve_actors? ? ActorResolver.call(refs) : refs.map!(&:without_resolution)

        events.zip(refs).map { |event, ref| timeline_entry(event, ref) }
      end
    end

    # §7: each enabled flag and reason is the guard's own answer, so the button and the command agree.
    # Empty with no actor, since every guard asks who is acting.
    def actions
      @actions ||= actor.nil? ? [] : ACTIONS.keys.filter_map { |name| action(name) }
    end

    # Built once per page and shared: the presenter's actions and anything else asking the same question.
    # Nil for an override the operation does not declare.
    def guard(name)
      guards.fetch(name) do
        spec = ACTIONS.fetch(name)

        guards[name] = (spec[:guard].new(request: request, actor: actor, **spec.fetch(:options, {})) if offered?(name))
      end
    end

    private

    def guards
      @guards ||= {}
    end

    def timeline_entry(event, actor_ref)
      Value::TimelineEntry.new(kind: event.kind.to_sym, actor: actor_ref, body: event.body,
                               detail: timeline_detail(event), metadata: event.metadata || {},
                               occurred_at: event.occurred_at, operation_version: event.operation_version)
    end

    def timeline_detail(event)
      metadata = event.metadata || {}

      case event.kind
      when "quorum_satisfied", "stage_satisfied" then satisfied_detail(metadata)
      when "overridden" then overridden_detail(metadata)
      when "reaped" then reaped_detail(metadata)
      when "execution_started", "executed", "execution_failed" then attempt_detail(metadata)
      end
    end

    # The quorum's label, or the stage's for a nameless quorum - which is what the metadata omits (§5.9).
    def satisfied_detail(metadata)
      return Value.label(:quorums, metadata["quorum"]) if metadata["quorum"].present?

      Value.label(:stages, metadata["stage"]) if metadata["stage"].present?
    end

    def overridden_detail(metadata)
      detail(:shortfall, "%{present} of %{required} approvals", present: metadata["approvals_present"],
                                                                 required: metadata["approvals_required"])
    end

    def reaped_detail(metadata)
      stuck_for = ActiveSupport::Duration.build(metadata["stuck_for"].to_i).inspect

      detail(:reaped, "Attempt %{attempt}, stuck for %{stuck_for}", attempt: metadata["attempt"], stuck_for: stuck_for)
    end

    def attempt_detail(metadata)
      detail(:attempt, "Attempt %{attempt}", attempt: metadata["attempt"]) if metadata["attempt"]
    end

    def detail(key, default, **values)
      Translation.translate("change_requests.timeline_details.#{key}", default: default, **values)
    end

    def offered?(name)
      name != :execute_override || operation&.overridable?
    end

    def operation
      ChangeRequests.operations[request.operation_key]
    end

    def action(name)
      checked = guard(name)

      return if checked.nil?

      spec = ACTIONS.fetch(name)

      Value::Action.new(name: name, enabled: checked.allowed?, reason: checked.message, tone: spec[:tone],
                        path: action_path(spec.fetch(:route, name)), confirm: confirmation(name),
                        requires_reason: requires_reason?(name, spec))
    end

    def requires_reason?(name, spec)
      return operation.override_policy.require_reason? if name == :execute_override

      spec.fetch(:requires_reason, false)
    end

    # Nil with no routes, and for a route the host did not draw (M6a-2).
    def action_path(route)
      helper = :"#{route}_request_path"

      routes.public_send(helper, request) if routes.respond_to?(helper)
    end

    # §8.1: an override is always confirmed, naming what it bypasses.
    def confirmation(name)
      return unless name == :execute_override

      shortfall = request.approval_shortfall
      missing = shortfall[:approvals_required] - shortfall[:approvals_present]
      plural = missing == 1 ? "one" : "other"
      default = "This bypasses %{count} required approval#{"s" unless missing == 1}. Continue?"

      Translation.translate("change_requests.confirmations.execute_override.#{plural}", default: default,
                                                                                         count: missing)
    end

    PROGRESS = {
      stages: { quorums: [:permissions, :eligible_actors, { approval_quorums: :approval }] },
    }.freeze
    private_constant :PROGRESS

    # Leaves anything already loaded alone, so M5-6's collection preload costs nothing here.
    def preload_progress
      ActiveRecord::Associations::Preloader.new(records: [request], associations: [PROGRESS, :events]).call
    end

    def stage_progress(stage)
      Value::StageProgress.new(
        name: stage.name, label: stage.label, position: stage.position, status: stage.status.to_sym,
        satisfied: stage.satisfied? || stage.closed?, current: current_stage?(stage),
        satisfied_by: stage.satisfied_by.to_sym, satisfied_via: satisfied_via(stage),
        remaining_options: remaining_options(stage),
        quorums: stage.quorums.sort_by(&:position).map { |quorum| quorum_progress(quorum) }
      )
    end

    def quorum_progress(quorum)
      Value::Quorum.new(name: quorum.name, label: quorum.label, required: quorum.threshold,
                        approved: quorum.approval_quorums.size, satisfied: quorum.satisfied?,
                        approvers: linked_approvals(quorum).map(&:approver_label))
    end

    # Snapshots, not live labels: who approved, as they were named when they did.
    def linked_approvals(quorum)
      quorum.approval_quorums.map(&:approval).sort_by(&:decided_at)
    end

    def current_stage?(stage)
      request.pending? && stage.position == request.current_stage_position
    end

    # Only an any_quorum stage closes through one route. stage_satisfied already records which (§7.1).
    def satisfied_via(stage)
      return unless stage.closed? && stage.any_quorum?

      event = request.events.to_a.rfind { |row| row.kind == "stage_satisfied" && row.metadata["stage"] == stage.name }

      event&.metadata&.fetch("quorum", nil)
    end

    # "2 more from Owners", one per quorum still short. The view joins them with "or" under
    # any_quorum and "and" under all_quorums; `satisfied_by` says which.
    def remaining_options(stage)
      return [] unless stage.pending?

      decided = stage.quorums.flat_map { |quorum| quorum.approval_quorums.map(&:approval) }
                     .to_set { |approval| [approval.approver_type, approval.approver_id] }

      stage.quorums.sort_by(&:position).reject(&:satisfied?).map do |quorum|
        remaining_option(quorum, decided)
      end
    end

    def remaining_option(quorum, decided)
      approved = quorum.approval_quorums.size
      key = approved.zero? ? "remaining" : "remaining_more"
      default = approved.zero? ? "%{count} from %{who}" : "%{count} more from %{who}"

      Translation.translate("change_requests.progress.#{key}", default: default,
                                                               count: quorum.threshold - approved,
                                                               who: remaining_who(quorum, decided))
    end

    # A quorum that only names people lists who is left of them (M9a-3). Anything else is its label.
    def remaining_who(quorum, decided)
      return quorum.label unless quorum.permissions.empty? && quorum.eligible_actors.any?

      quorum.eligible_actors.reject { |row| decided.include?([row.actor_type, row.actor_id]) }
            .map(&:actor_label)
            .join(" #{Translation.translate("change_requests.progress.or", default: "or")} ")
    end

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
