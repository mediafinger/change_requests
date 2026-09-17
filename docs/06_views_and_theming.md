# Views and theming

Everything the built-in UI renders comes from a presenter. Presenters need no view layer, so an API
controller, a mailer or a background job renders a request from the same values the UI does.

## Presenters

```ruby
p = ChangeRequests::RequestPresenter.new(request, actor: current_user, routes: nil, resolve_actors: true)
```

| Method              | Returns                                                                  |
|---------------------|--------------------------------------------------------------------------|
| `operation_key`     | `"members.update_roles"`                                                 |
| `operation_version` | the version the request was created under                                |
| `operation_label`   | `"Members::UpdateRoles.call"`, from the request's own columns            |
| `requester`         | `ChangeRequests::ActorRef`                                               |
| `executer`          | `ActorRef`, or `nil` until someone executes it                           |
| `tenant`            | `ActorRef`, or `nil`                                                     |
| `status`            | `Value::Status(key:, label:, tone:, tooltip:)`                           |
| `payload_fields`    | `[Value::Field(key:, label:, value:)]`, alphabetical by key              |
| `payload_preview`   | the first `config.payload_preview_limit` of `payload_fields`             |
| `stages`            | `[Value::StageProgress]` in position order                               |
| `actions`           | `[Value::Action]`, one per transition the acting actor could be offered   |
| `guard(name)`       | the `Guards::*` object behind an action, built once per presenter        |
| `timeline`          | `[Value::TimelineEntry]`, one per event, oldest first                    |

`as_json` arrives with the rest of M5.

A request whose operation is no longer declared renders exactly like any other. Nothing here reads the
declaration.

### A page of requests

```ruby
page = ChangeRequests::CollectionPresenter.new(
  ChangeRequests::Request.visible_to(current_user).order(created_at: :desc).limit(25),
  actor: current_user, routes: self,
)

page.each { |p| p.operation_label; p.requester.label; p.status; p.stages }
```

`CollectionPresenter` owns eager loading, so a page costs a fixed number of queries however many rows it
has:
- one for the requests;
- eight for what every presenter reads: stages, quorums, permissions, named approvers, approval links,
  approvals, events, attempts;
- one per actor class across every requester, executer, tenant and timeline actor on the page.

25 requests raised by Users, Admins and Managers in one Organization cost 13 queries, and so do 5.

Each presenter it yields is indistinguishable from `RequestPresenter.new(request, …)`. It already has its
associations loaded and its actors resolved. `resolve_actors: false` skips the actor queries and still
labels everyone.

`actions` is not preloaded: each guard asks its own questions, so an index that renders buttons pays for
them per row.

### Actors

`requester`, `executer` and `tenant` resolve together on first read: one query per actor class, then none.
A deleted actor never raises. `deleted?` is true, `label` falls back to the label snapshotted when the
row was written, and `path` is `nil`.

`resolve_actors: false` answers every actor from the row alone, with **no query against your tables**, even
under `config.actor_label_strategy = :live`. `deleted?` is then `false`, because nothing looked. Use it
for large index pages, and for requests whose actor class no longer exists.

`routes:` is whatever object your `t.path` lambdas call url helpers on, usually the view. Without it,
every `path` is `nil`.

### Payload

Fields are ordered **alphabetically by key**. `jsonb` does not keep insertion order, so no other ordering
is deterministic. A field's `value` is the `op.payload_labels` entry for that key when the declaration
produced one, and the raw value otherwise. Most fields having no label is normal.

```ruby
config.payload_preview_limit = 3                                          # default; 0 hides the preview
config.payload_renderer      = ->(request, view) { view.render "admin/payload", request: }
```

`payload_renderer` replaces the built-in payload partial. It needs a view, so the views call it and the
presenter does not.

### Status

| Status       | Tone       | Tooltip                                   |
|--------------|------------|-------------------------------------------|
| `pending`    | `neutral`  |                                           |
| `approved`   | `primary`  |                                           |
| `executing`  | `primary`  |                                           |
| `successful` | `success`  |                                           |
| `failed`     | `danger`   | the last failed attempt's error message   |
| `rejected`   | `danger`   |                                           |
| `canceled`   | `neutral`  | the cancellation reason                   |
| `expired`    | `warning`  | `Expired at <expires_at, ISO8601 UTC>`    |

A request **executed by override** has tone `warning` instead (a failed one stays `danger`), and a tooltip
naming the approvals it had, the approvals it needed and the override reason.

Tones are a closed set: `neutral`, `primary`, `success`, `warning`, `danger`.

### Stages

```ruby
Value::StageProgress(name: "operational", label: "Operational", position: 1, status: :pending,
                     satisfied?: false, current?: true, satisfied_by: :any_quorum, satisfied_via: nil,
                     remaining_options: ["1 from Admin", "1 more from Owners"],
                     quorums: [Value::Quorum(name: "admin",  label: "Admin",  required: 1, approved: 0, approvers: []),
                               Value::Quorum(name: "owners", label: "Owners", required: 2, approved: 1, approvers: ["Olga"])])
```

- **`approved` counts distinct people.** Under `all_quorums` one approval counts toward one quorum, so an
  Admin who also holds `owner` never fills both.
- **`remaining_options`** has one entry per quorum still short, and is empty unless the stage is `pending`.
  Join the entries with **or** under `satisfied_by: :any_quorum` and **and** under `:all_quorums`:
  "1 from Admin, or 1 more from Owners" is honest where "1/2" is not.
- A quorum that only **names** its approvers lists the ones who have not decided yet: "1 more from Gene".
- `satisfied_via` names the quorum that closed an `any_quorum` stage. It is `nil` for `all_quorums`, where
  every quorum did.
- `approvers` and named actors come from labels stored on the rows, so stages render in full with
  `resolve_actors: false` and after an approver is deleted.
- `current?` is the stage a pending request is waiting on. A finished request has none.

### Actions

```ruby
Value::Action(name: :approve, label: "Approve", enabled: false,
              reason: "This request is no longer open for decisions.",
              http_method: :post, path: "/change_requests/requests/…/approve",
              confirm: nil, tone: :primary, requires_reason: false)
```

| Action             | Tone      | Requires a reason                   | Path helper            |
|--------------------|-----------|-------------------------------------|------------------------|
| `approve`          | `primary` | no                                  | `approve_request_path` |
| `unapprove`        | `neutral` | no                                  | `unapprove_request_path` |
| `reject`           | `danger`  | yes                                 | `reject_request_path`  |
| `execute`          | `primary` | no                                  | `execute_request_path` |
| `execute_override` | `danger`  | `op.override(require_reason:)`      | `execute_request_path` |
| `cancel`           | `warning` | yes                                 | `cancel_request_path`  |
| `comment`          | `neutral` | no                                  | `comment_request_path` |

- **`enabled` and `reason` come from the guard the command enforces with.** A disabled button's tooltip is
  the exact sentence the command would raise, so the two cannot disagree.
- **`execute_override`** is listed only when the operation declares `op.override`. It is always confirmed
  ("This bypasses 2 required approvals. Continue?") and posts to Execute's path with `override: true`.
- `path` is `nil` without `routes:`, and for any action whose route your `config.routes` does not draw.
- With no `actor:`, `actions` is empty: every guard asks who is acting.
- `guard(:approve)` returns the same object the action was computed from, for anything else on the page
  asking the same question.

### Timeline

```ruby
Value::TimelineEntry(kind: :overridden, label: "Executed without approval", actor: ActorRef,
                     body: "Payment provider outage", detail: "1 of 2 approvals",
                     metadata: { "approvals_present" => 1, "approvals_required" => 2, … },
                     occurred_at: Time, operation_version: "2026-09-17")
```

- `body` is what the actor wrote: a comment, a rejection or cancellation reason, an override reason.
- `detail` is what the gem reads out of `metadata`, for the kinds that have something to say:

  | Kind                                               | `detail`                          |
  |----------------------------------------------------|-----------------------------------|
  | `quorum_satisfied`, `stage_satisfied`              | the quorum's label, or the stage's |
  | `overridden`                                       | "1 of 2 approvals"                |
  | `reaped`                                           | "Attempt 1, stuck for 2 hours"    |
  | `execution_started`, `executed`, `execution_failed` | "Attempt 1"                       |

- `metadata` is exactly what the event stored.
- **The System actor is an ordinary `ActorRef`**, labelled "System", never `deleted?`, with no path.
  Expiry, the reaper and stage closing render with no branch in your view.
- `operation_version` is stamped per event from the live declaration, so a declaration that changed
  mid-request shows as two versions on one timeline.
- Actors resolve together, one query per actor class, or not at all with `resolve_actors: false`.

## Labels and translations

Every label is looked up under `change_requests.*` and falls back to the humanized key, so nothing needs a
locale file:

```yaml
en:
  change_requests:
    fields:
      member_id: "Member"
    statuses:
      pending: "Awaiting approval"
      expired_tooltip: "Ran out at %{expires_at}"
      overridden_tooltip: "Forced through with %{present}/%{required} approvals: %{reason}"
    stages:
      sign_off: "Director sign-off"
    quorums:
      owners: "Owners"
    actions:
      execute_override: "Execute without approval"   # the gem ships every action label
    confirmations:
      execute_override:
        one: "This bypasses %{count} required approval. Continue?"
        other: "This bypasses %{count} required approvals. Continue?"
    timeline:                                # the gem ships a label for every kind
      requested: "Raised"
    timeline_details:
      shortfall: "%{present} of %{required} approvals"
      reaped: "Attempt %{attempt}, stuck for %{stuck_for}"
      attempt: "Attempt %{attempt}"
    progress:
      remaining: "%{count} from %{who}"
      remaining_more: "%{count} more from %{who}"
      or: "or"
```

Tooltip times are ISO8601 UTC. Format them for display in your view.
