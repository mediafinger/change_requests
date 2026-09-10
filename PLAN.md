# ChangeRequests - Implementation Plan

A Rails gem that puts approval gates in front of guarded operations. Instead of invoking a service directly, a host records the intent as a change request, execution is deferred until the declared approval workflow is satisfied.

**Date:** 2026-09-09

**Scope** of the first version: Ruby 4.x, Rails 8.x, PostgreSQL only, ERB views, configurable Actor classes and configurable approval logic for M-to-N approval workflows with Audit trails. _(older version and other DBs might be supported in future releases, if there is demand)_

## Table of contents

1. [Architecture](#1-architecture)
2. [Repository layout](#2-repository-layout)
3. [Naming](#3-naming)
4. [Table names](#4-table-names)
5. [Data model](#5-data-model)
6. [Using the gem - a host's walkthrough](#6-using-the-gem---a-hosts-walkthrough)
7. [Guards and commands](#7-guards-and-commands)
8. [Execution](#8-execution)
9. [Authorization and identity](#9-authorization-and-identity)
10. [Configuration](#10-configuration)
11. [Presenters](#11-presenters)
12. [Views](#12-views)
13. [Generators and templates](#13-generators-and-templates)
14. [Test kit for host apps](#14-test-kit-for-host-apps)
15. [The gem's own test suite](#15-the-gems-own-test-suite)
16. [Feature list for 1.0](#16-feature-list-for-10)
17. [Milestones](#17-milestones)
18. [Cut line for 1.0](#18-cut-line-for-10)
19. [Open decisions](#19-open-decisions)
20. [Appendix: salvage from the existing implementations](#20-appendix-salvage-from-the-existing-implementations)

## 1. Architecture

One gem, packaged as a mountable Rails engine, with a hard internal seam between a headless domain core and
an optional Rails/UI layer.

```
change_requests (one gem, one repo, one release cycle)
│
├── lib/change_requests/**          ← DOMAIN CORE.  ActiveRecord + ActiveSupport only.
│                                     Models, operations, guards, commands, presenters, errors,
│                                     events. Usable from a job, a console, an API, Avo,
│                                     Administrate, a rake task - no Rails::Engine required.
│
├── lib/change_requests/engine.rb   ← RAILS INTEGRATION.  Loaded only when Rails::Engine is
│                                     defined. Mounting the UI is opt-in.
│
├── app/controllers, app/views      ← OPTIONAL UI.  ERB. Every partial renders a presenter.
│   app/helpers, config/routes.rb      Overridable per-file by Rails view-path precedence.
│
└── lib/generators/**               ← INSTALL / EJECT / SCAFFOLD.
    lib/change_requests/rspec.rb    ← TEST KIT for host apps.
```

Constraints this design commits to:

- **`isolate_namespace ChangeRequests`** - no constant or route leakage into the host.
- **Domain code lives in `lib/`, not `app/models`**, so it loads without `Rails::Engine`. The engine
  contributes only `app/controllers`, `app/views`, `app/helpers` and `config/routes.rb`.
- **`config.mount_ui = false`** yields a pure domain + JSON gem; `true` yields a working approvals screen.
- **Migrations are generated into the host** by `rails g change_requests:install`, not appended from the
  engine's `db/migrate`. Generated migrations are inspectable, editable, and versioned in the host's repo.
- **No host constants in the domain layer.** No `belongs_to` to a host model, no `current_*` call, no
  `Rails.` reference. Enforced by CI (§2).

The domain is an aggregate with nine tables, a lifecycle, migrations and an authorization boundary build as an
engine. One optional mixin exists for host actor models:

```ruby
class Admin < ApplicationRecord
  include ChangeRequests::Actor
  # #change_requests, #change_request_approvals, #executed_change_requests,
  # #pending_change_request_approvals - scopes over (type, id) columns, not associations
end
```

A future split into `change_requests` + `change_requests-rails` stays cheap: the directory boundary and the
headless CI job (§15.5) mean it would be a `git mv` and a gemspec.

## 2. Repository layout

```
change_requests/
├── change_requests.gemspec
├── Gemfile
├── gemfiles/                                  # CI matrix (rails_7.1.gemfile … rails_8.1.gemfile)
├── Rakefile                                   # rake ci => rubocop + rspec + bundle:audit
├── README.md  CHANGELOG.md  LICENSE.txt  CODE_OF_CONDUCT.md
├── docs/
│   ├── 01_getting_started.md
│   ├── 02_operations.md
│   ├── 03_approval_workflows.md               # flat N-of-M and staged M-to-N
│   ├── 04_authorization.md
│   ├── 05_execution_and_idempotency.md
│   ├── 06_views_and_theming.md                # the §12 tiers, with the partial/locals contract
│   ├── 07_testing.md                          # the host test kit
│   ├── 08_events_and_notifications.md
│   ├── 09_upgrading.md
│   └── 10_migrating_an_existing_implementation.md
│
├── lib/
│   ├── change_requests.rb                     # entrypoint: Zeitwerk loader, .configure, .operations, .request!
│   └── change_requests/
│       ├── version.rb
│       ├── configuration.rb
│       ├── errors.rb                          # the error taxonomy
│       │
│       ├── models/                            # ── LAYER 1: DOMAIN (AR + AS only) ──
│       │   ├── record.rb                      # abstract base; connection/table config
│       │   ├── request.rb
│       │   ├── stage.rb
│       │   ├── quorum.rb
│       │   ├── quorum_permission.rb
│       │   ├── quorum_eligible_actor.rb
│       │   ├── approval.rb
│       │   ├── approval_quorum.rb
│       │   ├── event.rb
│       │   └── attempt.rb
│       ├── operations.rb                     # the collection: define, [], keys, verify!
│       ├── operation.rb                      # one entry
│       ├── operation/workflow.rb             # stage + quorum definitions
│       ├── guards/                            # allowed? + reason, shared by commands AND presenters
│       │   ├── base.rb approve.rb unapprove.rb reject.rb execute.rb cancel.rb comment.rb expire.rb
│       ├── commands/                          # guard + mutate + emit event, inside with_lock
│       │   ├── base.rb create.rb approve.rb unapprove.rb reject.rb execute.rb cancel.rb comment.rb expire.rb
│       │   └── evaluate_workflow.rb          # advance the workflow after a decision - §7.1
│       ├── authorization/
│       │   ├── permissions.rb                 # default: set inclusion
│       │   └── callable.rb                    # wraps any ->(actor:, request:, action:) {}
│       ├── execution/
│       │   ├── dispatcher.rb                  # operation lookup + invoke
│       │   ├── runner.rb                      # attempt bookkeeping, idempotency, retry ceiling
│       │   ├── job.rb                         # ActiveJob, only defined if ActiveJob is present
│       │   └── close_stage_job.rb             # ActiveJob, cooldown fast path - §7.1
│       ├── presenters/                        # ── LAYER 2: PRESENTATION-AGNOSTIC ──
│       │   ├── request_presenter.rb
│       │   ├── collection_presenter.rb
│       │   └── value/{action.rb,status.rb,stage_progress.rb,timeline_entry.rb}
│       ├── notifications.rb                   # ActiveSupport::Notifications + config hooks
│       ├── maintenance.rb                     # expire_stale!, reap_stuck_executions!, cancel_undeclared!,
│       │                                     # close_due_stages!
│       ├── actor.rb                           # the optional host-model concern
│       │
│       ├── engine.rb                          # ── LAYER 3: RAILS ── (required only if Rails::Engine)
│       ├── rspec.rb                           # host test kit entrypoint
│       ├── testing.rb                         # host test kit implementation
│       └── factories.rb                       # optional FactoryBot definitions
│
├── app/                                       # engine-only; never loaded headless
│   ├── controllers/change_requests/{base_controller.rb,requests_controller.rb}
│   ├── helpers/change_requests/requests_helper.rb
│   └── views/change_requests/requests/*.html.erb
│
├── config/
│   ├── routes.rb
│   └── locales/en.yml
│
├── lib/generators/change_requests/
│   ├── install/         install_generator.rb + templates/{initializer.rb.tt,operations.rb.tt,migration.rb.tt,spec_support.rb.tt}
│   ├── action/          action_generator.rb  + templates/{action.rb.tt,action_spec.rb.tt}
│   ├── controller/      controller_generator.rb + templates/controller.rb.tt
│   ├── views/           views_generator.rb   # eject engine ERB, --only supported
│   └── scaffold_ui/     scaffold_ui_generator.rb # write host-namespaced views + controller
│
└── spec/
    ├── dummy/                                 # runnable demo app (bin/demo)
    ├── models/ operations/ guards/ commands/ execution/ presenters/
    ├── requests/                              # controller + view rendering
    ├── generators/
    ├── integration/{concurrency_spec.rb,headless_spec.rb,packaging_spec.rb}
    └── support/
```

**Dependency rule, enforced in CI:** nothing under `lib/change_requests/{models,operation,guards,commands,
authorization,execution,presenters}` may reference `ActionController`, `ActionView`, `Rails`, or any constant
under `app/`. `spec/integration/headless_spec.rb` proves it by booting the core against a bare ActiveRecord
connection with `Rails` undefined.

**Autoloading:** `Zeitwerk::Loader.for_gem` over `lib/`, with `lib/generators` and `lib/change_requests/rspec.rb`
ignored (generators are loaded by Rails' own generator lookup; the test kit is explicitly required). The
existing `zeitwerk` runtime dependency in the gemspec is correct and stays.

`models/` and `presenters/` are **collapsed** - `loader.collapse("lib/change_requests/models")` and the same
for `presenters` - so `models/request.rb` defines `ChangeRequests::Request` and
`presenters/request_presenter.rb` defines `ChangeRequests::RequestPresenter`, as §3 and §11 name them. The
directories are a filing convention, not a namespace. Every other directory (`guards/`, `commands/`,
`authorization/`, `execution/`) *is* a namespace and is not collapsed.

**Table names are derived, not written.** `ChangeRequests.table_name_prefix = "change_request_"` is defined
in `lib/change_requests.rb`, before `engine.rb` is loaded - `isolate_namespace` installs its own
`table_name_prefix` only `unless mod.respond_to?(:table_name_prefix)`, so ours wins, and it applies headless
where no engine exists at all. Every model in §4 then derives its table name by convention. `Request` is the
single exception: it would derive `change_request_requests`, so it carries an explicit
`self.table_name = "change_requests"`.

**Runtime dependencies:** `activerecord >= 7.1`, `activesupport >= 7.1`, `zeitwerk >= 2.6`. `railties` is
a *development* dependency plus an optional runtime one - declare it runtime only if the engine is the primary
delivery (it is), but keep every `require "rails/..."` behind `defined?(Rails::Engine)`. No `pg` runtime
dependency: PostgreSQL-only is a documented requirement, not a gem constraint on the host's adapter gem
version.

## 3. Naming

**Nouns are records, verbs are commands.** `Approval` is a row; `Approve` is a thing you do.

| Concept                      | Constant                                        |
|------------------------------|-------------------------------------------------|
| The request record           | `ChangeRequests::Request`                       |
| A step                       | `ChangeRequests::Stage`                         |
| A counting rule in a step    | `ChangeRequests::Quorum`                        |
| Eligibility by permission    | `ChangeRequests::QuorumPermission`              |
| Eligibility by name          | `ChangeRequests::QuorumEligibleActor`           |
| An approval record           | `ChangeRequests::Approval`                      |
| What an approval counted for | `ChangeRequests::ApprovalQuorum`                |
| An audit row                 | `ChangeRequests::Event`                         |
| An execution attempt         | `ChangeRequests::Attempt`                       |
| A transition                 | `ChangeRequests::Commands::{Approve,Execute,…}` |
| Command base                 | `ChangeRequests::Commands::Base`                |
| Workflow evaluation          | `ChangeRequests::Commands::EvaluateWorkflow`    |
| Base error                   | `ChangeRequests::Error` (+ taxonomy, §7)        |

**Gateable things are operations.** The host-facing surface is
`ChangeRequests.operations.define "…" do |op|` - flat calls, no wrapper block, so declarations split across
`config/change_requests/*.rb` naturally.

| Element        | Name                                                                        |
|----------------|-----------------------------------------------------------------------------|
| The collection | `ChangeRequests.operations` - an instance of `ChangeRequests::Operations`   |
| One entry      | `ChangeRequests::Operation`, declared with `.define "members.update_roles"` |
| Its parts      | `Operation::Workflow`                                                       |
| Its key        | `operation_key` (column and API)                                            |
| The target     | `op.service` + `op.method_name`                                             |
| Its version    | `op.version`, snapshotted as `operation_version`                            |
| Not found      | `ChangeRequests::UnknownOperation`                                          |

Names unavailable for the collection, for collision rather than taste: `workflow` (already `op.workflow` and
a column), `policies` (Pundit, ActionPolicy), `actions` (Rails controller actions).

## 4. Table names

| Table                                   | Stores                                                                                                |
|-----------------------------------------|-------------------------------------------------------------------------------------------------------|
| `change_requests`                       | a deferred action: operation key, payload, status, requester, frozen workflow snapshot                |
| `change_request_approval_quorums`       | which quorums an approval counted toward, resolved at decision time                                   |
| `change_request_approvals`              | one approver's decision on one stage: `approve` or `reject`, with frozen label and identity snapshots |
| `change_request_attempts`               | one execution attempt: token, timings, outcome, error class and message                               |
| `change_request_events`                 | the append-only audit trail: one immutable row per transition, comment, failure or override           |
| `change_request_quorum_eligible_actors` | eligibility by name: one specific actor, by type and id                                               |
| `change_request_quorum_permissions`     | eligibility by permission x actor type, nullable on both axes                                         |
| `change_request_quorums`                | one counting rule within a stage: `threshold`, `permission_match`                                     |
| `change_request_stages`                 | the ordered steps: `satisfied_by`, satisfaction and closing state                                     |

Every name above is **derived** from `ChangeRequests.table_name_prefix = "change_request_"` plus the model's
own name (§2). Only `change_requests` is set explicitly, because `Request` would otherwise derive
`change_request_requests`. Nothing else in the gem writes `self.table_name`, and a spec asserts that.

## 5. Data model

Designed for staged M-to-N **from the first migration**. A flat 1-of-N request is simply a request with one
stage. This avoids a painful schema migration later, and costs one extra table now.

### 5.1 `change_requests`

| Column                      | Type                                  | Notes                                                          |
|-----------------------------|---------------------------------------|----------------------------------------------------------------|
| `id`                        | uuid (or bigint)                      | PK type chosen at install time                                 |
| `operation_key`             | string, not null                      | operation key, e.g. `"members.update_roles"`                   |
| `service`                   | string, not null                      | resolved from the operation **at creation**, stored for audit  |
| `method_name`               | string, not null                      | ditto                                                          |
| `operation_version`         | string, not null                      | `op.version` as declared at creation - see §5.10               |
| `payload`                   | jsonb, not null, default `{}`         | `attr_readonly` after create                                   |
| `status`                    | string, not null, default `"pending"` | **not** a PG enum - see §5.7                                   |
| `requester_type`            | string, not null                      | `"User"`, `"Admin"`, … - allowlisted, see §5.7                 |
| `requester_id`              | **string**, not null                  | string so heterogeneous PK types can share the column          |
| `requester_label`           | string, not null                      | snapshot at creation; outlives the actor record                |
| `executer_type`             | string, null                          |                                                                |
| `executer_id`               | string, null                          |                                                                |
| `executer_label`            | string, null                          | snapshot at execution                                          |
| `tenant_type`               | string, null                          | always created; null unless `config.tenant_type` is configured |
| `tenant_id`                 | string, null                          |                                                                |
| `tenant_label`              | string, null                          | snapshot at creation                                           |
| `payload_labels`            | jsonb, not null, default `{}`         | snapshot of human labels for the records the payload refers to |
| `current_stage_position`    | integer, not null, default 1          | stages are always sequential - see §5.2                        |
| `max_attempts`              | integer, not null, default 1          | snapshot from the operation; attempts are counted in §5.6      |
| `expires_at`                | datetime, null                        |                                                                |
| `executed_at`               | datetime, null                        | set on successful execution                                    |
| `overridden_at`             | datetime, null                        | set when executed without the required approvals - see §8.1    |
| `lock_version`              | integer, not null, default 0          | optimistic lock, belt to `with_lock`'s braces                  |
| `created_at` / `updated_at` | datetime, not null                    |                                                                |

Indexes: `(status)`, `(tenant_type, tenant_id, status, created_at DESC)`, `(requester_type, requester_id)`,
`(executer_type, executer_id)`, `(operation_key)`, `(expires_at)`
where `status IN ('pending','approved')` (partial index for the expiry sweeper), and `(overridden_at)`
where not null - overrides are the rows a compliance review asks for first.

Creation-time facts are immutable rather than merely conventionally so: `operation_key`,
`operation_version`, `service`, `method_name`, `payload`, `payload_labels`, `requester_type`, `requester_id`,
`requester_label`, `tenant_type`, `tenant_id`, `max_attempts`.

**Enforced by an own `before_update` guard that raises `ChangeRequests::ReadonlyAttribute`, not by
`attr_readonly`.** Rails' `attr_readonly` silently discards the assignment unless the *host application*
has `config.active_record.raise_on_assign_to_attr_readonly` enabled - a setting an engine cannot control,
and silence is the one behaviour this column list exists to prevent.

Approval policy is not duplicated onto this row. It is materialised into stages and quorums (§5.2, §5.3) at
creation, and those rows are the frozen snapshot.

### 5.2 `change_request_stages`

Stages are always sequential. Parallelism within a step is one stage with several quorums (§5.3); ordered
groups are consecutive stages. There is no request-level mode column.

| Column              | Type                                     | Notes                                              |
|---------------------|------------------------------------------|----------------------------------------------------|
| `id`                | uuid/bigint                              |                                                    |
| `change_request_id` | FK, not null                             |                                                    |
| `position`          | integer, not null                        | unique with request_id; stages advance in order    |
| `name`              | string, not null                         | declaration identifier, `snake_case`; §5.9         |
| `satisfied_by`      | string, not null, default `"any_quorum"` | `any_quorum` \| `all_quorums`                      |
| `satisfied_at`      | datetime, null                           | when its quorums were first met                    |
| `closed_at`         | datetime, null                           | when it became immutable - §7.1                    |
| `status`            | string, not null, default `"pending"`    | `pending` \| `satisfied` \| `closed` \| `rejected` |

Unique indexes `(change_request_id, position)` and `(change_request_id, name)`.

Stages are materialised from the operation when the request is created; their definition is never edited.
A stage's lifecycle is `pending → satisfied → closed`, and a **closed stage is immutable** (§7.1).

### 5.3 `change_request_quorums`

A stage holds one or more **quorums**. A quorum is a `threshold` plus an eligibility set: it is satisfied
when `threshold` distinct eligible actors have approved. The stage is satisfied when **any** of its quorums
is, or **all**, per `satisfied_by`. Counting approvals is the only rule; there is no rule column.

| Column                    | Type                                  | Notes                                                            |
|---------------------------|---------------------------------------|------------------------------------------------------------------|
| `id`                      | uuid/bigint                           |                                                                  |
| `change_request_stage_id` | FK, not null                          |                                                                  |
| `position`                | integer, not null                     | unique with stage_id; display order only                         |
| `name`                    | string, null                          | declaration identifier; null when the stage has one quorum; §5.9 |
| `threshold`               | integer, not null                     | how many approvals satisfy this quorum                           |
| `permission_match`        | string, not null, default `"any"`     | `any` \| `all` - per quorum                                      |
| `status`                  | string, not null, default `"pending"` | `pending` \| `satisfied`                                         |
| `satisfied_at`            | datetime, null                        |                                                                  |

Unique indexes `(change_request_stage_id, position)` and `(change_request_stage_id, name)` where name is
not null.

This is the level that carries the threshold, which is the whole point: **one integer per stage cannot
express "one Admin *or* two Owners"** - two quorums with different thresholds can.

```
request
  └─ stages            ordered, sequential, advance one at a time
       └─ quorums      OR-ed or AND-ed within the stage (satisfied_by)
            ├─ permission rows       who qualifies, by permission x actor type
            └─ eligible actor rows   who qualifies, by name
```

Keep the axes distinct: permission and eligible-actor rows decide **who may** approve; `threshold` decides
**how many** must; `satisfied_by` decides **which quorums** have to be met.

#### Eligibility rows

| `change_request_quorum_permissions` | Type         | Notes                                        |
|-------------------------------------|--------------|----------------------------------------------|
| `change_request_quorum_id`          | FK, not null |                                              |
| `permission`                        | string, null | `NULL` = any permission (gate on type alone) |
| `actor_type`                        | string, null | `NULL` = any registered actor type           |

CHECK: `permission IS NOT NULL OR actor_type IS NOT NULL` - a row that constrains nothing is a bug, not a
wildcard.

| `change_request_quorum_eligible_actors` | Type             |
|-----------------------------------------|------------------|
| `change_request_quorum_id`              | FK, not null     |
| `actor_type`                            | string, not null |
| `actor_id`                              | string, not null |

Unique indexes `(quorum_id, permission, actor_type)` - declared **`nulls_not_distinct: true`**, because both
columns are nullable and PostgreSQL otherwise treats every NULL as distinct, which would let the "any
permission / any actor type" rows be inserted twice - and `(quorum_id, actor_type, actor_id)`; reverse
indexes `(permission)` and `(actor_type, actor_id)` for the inbox query.

**The 2x2 eligibility matrix** can flexibly handle multiple actor classes or apps which use one actor class with multiple roles:

| `actor_type` | `permission` | Means                                         | Typical app using this has         |
|--------------|--------------|-----------------------------------------------|------------------------------------|
| `User`       | `editor`     | Users with the role or permission `editor`    | several classes, e.g. User & Admin |
| `NULL`       | `editor`     | anyone with the role or permission `editor`   | single User class + roles          |
| `Admin`      | `NULL`       | any Admin, whatever their roles or permission | several classes, e.g. User & Admin |
| `NULL`       | `NULL`       | *rejected*                                    | -                                  |

`permission_match` sits on the **quorum**, not in global config: multiple rows mean "any of these" under
`:any` and "all of these" (a per-actor AND - *this* actor holds every listed permission) under `:all`.
Identical rows, opposite meanings, so the mode belongs beside the rows it governs. `config` supplies only
the default.

#### `change_request_approval_quorums` - which quorums an approval counted toward

| Column                       | Type         |
|------------------------------|--------------|
| `change_request_approval_id` | FK, not null |
| `change_request_quorum_id`   | FK, not null |

Write-once, evaluated **at decision time**, unique on the pair. Two reasons it exists rather than re-deriving eligibility when counting:

1. **Counting becomes a `GROUP BY`** instead of re-evaluating every approver against every quorum.
2. **An approval stays counted when the approver's permissions later change.** Re-derivation would let a
   role change silently un-approve a request - the same class of bug as recomputing labels instead of
   snapshotting them (§5.7).

Under `all_quorums`, an approval links to **exactly one** quorum - the lowest-`position` quorum the actor
qualifies for. If Edith holds both `admin` and `owner`, her single approval cannot close both: "1 Admin and
2 Owners" means three people. Under `any_quorum` an approval links to every quorum it matches, since
satisfying any one of them ends the stage.

> The enforcement key is `(approver_type, approver_id)`, so this is airtight **within** an actor class. Across
classes the gem cannot know that `Admin#7` and `User#99` are the same human - two records, two deliberate
operations, two attributed rows. That is a human problem, and the events table is the mitigation.
`config.actor_identity` (§11) is the opt-in lever for hosts that *do* have a shared identity.

#### The approver inbox

> **Gem internals.** Hosts call `Request.awaiting_approval_from(actor)` (§6.7); this is what it compiles to.

"Every request awaiting *my* approval" is the badge in the navigation, the target list for notifications,
and the first thing anyone asks a change-request system for. Because eligibility is rows, it is one
indexed, paginated query rather than a scan:

```sql
-- "does this actor satisfy this permission row" - shared by both match modes
WITH matched AS (
  SELECT p.change_request_quorum_id AS quorum_id, p.id AS row_id
    FROM change_request_quorum_permissions p
   WHERE (p.permission IS NULL OR p.permission IN (:actor_permissions))
     AND (p.actor_type  IS NULL OR p.actor_type  =  :actor_type)
),
eligible_quorums AS (
  SELECT q.id, q.change_request_stage_id
    FROM change_request_quorums q
   WHERE q.status = 'pending'
     AND ( CASE q.permission_match
             WHEN 'any' THEN EXISTS (SELECT 1 FROM matched m WHERE m.quorum_id = q.id)
             WHEN 'all' THEN (SELECT COUNT(*) FROM matched m WHERE m.quorum_id = q.id)
                           = (SELECT COUNT(*) FROM change_request_quorum_permissions p
                               WHERE p.change_request_quorum_id = q.id)
           END
           OR EXISTS (SELECT 1 FROM change_request_quorum_eligible_actors e
                       WHERE e.change_request_quorum_id = q.id
                         AND e.actor_type = :actor_type AND e.actor_id = :actor_id) )
)
SELECT r.* FROM change_requests r
  JOIN change_request_stages s ON s.change_request_id = r.id
                              AND s.position = r.current_stage_position
                              AND s.status   = 'pending'
  JOIN eligible_quorums eq ON eq.change_request_stage_id = s.id
 WHERE r.status = 'pending'
   AND NOT EXISTS (SELECT 1 FROM change_request_approvals a
                    WHERE a.change_request_stage_id = s.id
                      AND a.approver_type = :actor_type AND a.approver_id = :actor_id)
   AND (r.requester_type, r.requester_id) IS DISTINCT FROM (:actor_type, :actor_id)
 GROUP BY r.id
```

The `all` branch is a count-match rather than a plain `IN`, which is precisely why the mode has to be a
column - the query shape differs per quorum. As a `text[]` this needs `&&` and a GIN index; as `jsonb` it
needs containment operators; in Ruby it cannot be paginated at all. Ships as
`ChangeRequests::Request.awaiting_approval_from(actor)`, and `Guards::Approve` evaluates the identical
predicate against a single loaded quorum - one definition of eligibility, two call sites, asserted equal by
a spec over every cell of the 2x2 (§15.2).

Every table in §5.3 is write-once, materialised when the stage is created from the frozen workflow, and
never updated - so a `permissions` list edited in an operation never changes who may approve an in-flight
request.

### 5.4 `change_request_approvals`

| Column                    | Type               | Notes                                    |
|---------------------------|--------------------|------------------------------------------|
| `id`                      | uuid/bigint        |                                          |
| `change_request_id`       | FK, not null       | denormalised for cheap counting/scoping  |
| `change_request_stage_id` | FK, not null       |                                          |
| `approver_type`           | string, not null   | allowlisted, see §5.7                    |
| `approver_id`             | string, not null   |                                          |
| `approver_label`          | string, not null   | snapshot at decision time                |
| `approver_identity`       | string, null       | `config.actor_identity` snapshot, if set |
| `decision`                | string, not null   | `approved` \| `rejected`                 |
| `comment`                 | text, null         |                                          |
| `decided_at`              | datetime, not null |                                          |
| `created_at`/`updated_at` | datetime, not null |                                          |

Which quorums the approval counted toward is recorded in `change_request_approval_quorums` (§5.3), never
re-derived.

**Unique index `(change_request_stage_id, approver_type, approver_id)`** - the DB, not application code,
enforces one-decision-per-approver-per-stage. The type is part of the key: `User#7` and `Admin#7` are two
different people.

### 5.5 `change_request_events` - the audit trail

Append-only, immutable, one row per transition. This is the audit trail; no free-text column on the
request is authoritative.

| Column              | Type                          | Notes                                                      |
|---------------------|-------------------------------|------------------------------------------------------------|
| `id`                | uuid/bigint                   |                                                            |
| `change_request_id` | FK, not null                  |                                                            |
| `actor_type`        | string, not null              | `"System"` for gem-originated events - see below           |
| `actor_id`          | string, not null              | `"system"` for the system actor - never a host id          |
| `actor_label`       | string, not null              | snapshot; `"System"` for gem-originated events             |
| `kind`              | string, not null              | inclusion validation, **no CHECK** - see below             |
| `operation_version` | string, not null              | the version in effect when this event occurred - see below |
| `body`              | text, null                    | free text: comment body, rejection reason, failure message |
| `metadata`          | jsonb, not null, default `{}` | stage name, attempt number, previous status, …             |
| `occurred_at`       | datetime, not null            |                                                            |

Kinds: `requested`, `approved`, `unapproved`, `rejected`, `commented`, `canceled`, `quorum_satisfied`,
`stage_satisfied`, `stage_closed`, `overridden`, `execution_started`, `executed`, `execution_failed`,
`expired`, `reaped`, `operation_undeclared`.

`kind` is enforced by an **inclusion validation only, with no CHECK constraint**. Every later milestone adds
kinds, and a CHECK would make each one a migration in every host application - a cost with no matching
benefit, since nothing but the gem ever writes this table.

**The system actor is a sentinel, not a NULL.** Gem-originated events (expiry, the reaper, undeclared-
operation cancellation, cooldown stage closing) are written with
`actor_type: "System", actor_id: "system", actor_label: "System"` - `ChangeRequests::SYSTEM_ACTOR`. It is
exempt from the registered-type allowlist, and the columns are `not null`, so "who did this" is answerable
for every row and no presenter or export has to branch on nil.


`stage_satisfied` carries `metadata: { quorum: "admin" }` when the stage has named quorums, so a stage met
through a one-admin shortcut is distinguishable in the timeline from one met the long way; the key is
omitted for single-quorum stages (§5.9). `overridden` is §8.1.

**`operation_version` is the declared version at the moment of the event**, read live from
`ChangeRequests.operations[request.operation_key]` when the row is written, and is deliberately *not* the
same field as `change_requests.operation_version`. The request holds the version it was created under; the
event holds the version in force when that particular transition happened. They diverge whenever a
declaration changes during a request's life - which matters most for `executed`, since dispatch resolves the
operation live while the approval workflow stays frozen at creation. A request approved under one version
and executed under another is exactly the fact an audit asks about, and joining events to the request would
report the wrong answer.

`op.version` is mandatory, so a declared operation always has one and the column is `not null`. A request
whose operation is undeclared is not workable at all (§5.11), so the only event ever written without a live
declaration is the `operation_undeclared` cancellation itself - which records the request's creation-time
version, that being the version whose disappearance the event is reporting.

Every event is written through one path (`emit` in `Commands::Base`, §7), so the column is populated in a
single place. Its presence also makes the table self-contained: `change_request_events` can be exported
alone as a complete audit log, with no join required.

Index `(change_request_id, occurred_at)`. No `updated_at` - rows are immutable; enforce with
`before_update { raise ActiveRecord::ReadOnlyRecord }` **and `before_destroy` with the same raise**.
Append-only means both: an audit trail a caller can quietly delete a row from is not one. The only path that
removes events is the request's own `ON DELETE CASCADE`, which the gem itself never triggers. A documented PG
rule/trigger snippet ships for hosts that want it enforced below the application.

**Commenting on completed requests is allowed.** Post-mortem notes on a `successful` or `canceled` request
are the point of an audit trail. Terminal-state protection applies to the request
row's lifecycle columns, not to appending events.

### 5.6 `change_request_attempts`

| Column                                                                                                                                                                        | Type | Notes                                |
|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------|--------------------------------------|
| `id`, `change_request_id` FK, `number` int                                                                                                                                    |      | unique `(change_request_id, number)` |
| `executer_type`/`executer_id`/`executer_label`, `started_at`, `finished_at`, `outcome` (`succeeded`\|`failed`\|`abandoned`), `error_class`, `error_message`, `backtrace` text |      |                                      |

**This table is the attempt counter.** There is no `attempts_count` column on the request: `number` is
`attempts.count + 1`, assigned inside T1's lock, and the unique index on `(change_request_id, number)` is what
makes a double claim impossible. A counter column would be a second source of truth for something these rows
already state.

This is what makes "did the outbound call happen before it blew up?" answerable, and what makes a retry
ceiling enforceable. There is no `failure_reason` column on the request: the message lives on the failed
attempt and in the `execution_failed` event, and the presenter reads the latest of those.

### 5.7 Schema principles

**No PostgreSQL enums.** Status and other enumerated columns are `string` + an inclusion validation + a
CHECK constraint in the generated migration. A PG enum makes migrations depend on application config at
migration time and needs a hand-written `ALTER TYPE … ADD VALUE` per new value; it buys nothing here.

**No foreign keys to host tables. Polymorphic actor references, chosen per request, with snapshotted
labels.**

Two requirements drive this:

- **Several actor classes coexist in one app** - `User`, `Admin`, `Manager` - and which one applies is
  decided **when the change request is created**, never at install time.
- **A deleted actor must not break a historical view.** The same holds for records the payload refers to.
  An audit trail that stops rendering because someone was offboarded is not an audit trail.

So every reference to a host record is a **triple**:

| Concern         | Column    | Notes                                                           |
|-----------------|-----------|-----------------------------------------------------------------|
| Which class     | `*_type`  | string, validated against the configured allowlist (§10)        |
| Which record    | `*_id`    | **string**                                                      |
| What to display | `*_label` | captured at write time, readonly after create, never recomputed |

Applied to `requester`, `executer`, `approver`, event `actor`, attempt `executer` and `tenant`.

Six consequences, each deliberate:

1. **`*_id` is a `string` column.** It has to be: a `User` with a uuid PK and an `Admin` with a bigint PK
   must sit in the same column. Casting back happens in the resolver, which knows each registered type's
   key type. That is the price of heterogeneous actors, and it is the right one - the alternative is a
   column per actor class, which is not extensible by a host at all.

2. **No foreign keys to host tables, and no `belongs_to`.** Between the gem's *own* tables
   (`change_request_id`, `change_request_stage_id`) foreign keys and `ON DELETE CASCADE` stay - those
   are internal and their integrity is the gem's business. Nothing points at a host table.

3. **Labels are snapshots, not lookups.** `requester_label` is written once, at creation, and never
   updated. A view of a three-year-old request renders correctly with the host's `users` table dropped
   entirely. Rendering is a column read; it does not touch the actor's table at all unless the presenter
   is asked to resolve live records.

4. **Live records are still resolved when they exist**, so a renamed user shows their current name and
   a link to their page. `ChangeRequests::ActorRef#label` prefers the live record and falls back to the
   snapshot, marking itself `deleted?`. `config.actor_label_strategy = :snapshot` flips the preference for
   hosts that want strict point-in-time audit semantics (§19.5).

5. **`actor_type.constantize` is the same hazard as `service.constantize`** and gets the same answer: the
   registered actor types are an allowlist, checked before the string is ever constantized, and validated
   on write so a typo fails at creation rather than at render time.

6. **The boot-order gotcha disappears.** With no `belongs_to` to install, there is no
   `config.to_prepare` dance, no dependency on host constants being loaded, and no `NoMethodError on nil`
   when the initializer has not run. The domain models now reference *zero* host constants, which
   materially strengthens the headless seam in §3 - `spec/integration/headless_spec.rb` can create,
   approve and execute a request with no host models defined at all.

**The honest trade:** there is no referential integrity on these columns. A dangling
`requester_type/requester_id` is possible, and by design - it renders as "Ada Lovelace (deleted)" instead
of raising. Two mitigations ship:
`rake change_requests:verify_actors` reports dangling references per type as a report, never as an
enforcement; and `payload_labels` (below) does the same job for the records a payload points at.

**PostgreSQL only, but nothing that blocks a port.** The gem is PostgreSQL-only at 1.0 and says so
loudly. No compatibility layer, no adapter branches, no MySQL or SQLite code paths, no second CI adapter -
those may never be wanted, and speculative portability shims are pure cost.

What *is* deliberate is not painting into a corner, because these three choices are free now and expensive
to unwind after data exists:

- **No array columns.** Quorum permissions and named approvers are join tables (§5.3) - which is the
  better design anyway, since it is what makes the approver inbox a paginatable query.
- **`jsonb` for storage, never for correctness.** `payload`, `payload_labels` and event
  `metadata` are written and read whole, in Ruby. No `@>`, no `->>`, no GIN index is load-bearing. A jsonb
  operator may be used as an *optimisation* behind a method, never as the only implementation of a
  behaviour.
- **Partial indexes are optimisations, not semantics.** Correctness never depends on one; every partial
  index in §5.1 could be a plain index at some cost in size.

Everything else stays unapologetically PostgreSQL: `jsonb` (not `json`), partial indexes, `FOR UPDATE`.
Note that §9's atomic claim is a conditional `UPDATE … WHERE status = …` with a zero-rows check rather than
a `FOR UPDATE` read - chosen for correctness, portable as a side effect.

**Payload records get the same treatment.** An operation may declare how to label the records its
payload references, and the result is snapshotted at creation:

```ruby
op.payload_labels = ->(payload) { { member_id: Member.find_by(id: payload[:member_id])&.name } }
```

`payload_labels` is **sparse**: declare a label only for payload keys whose raw value is meaningless to a
human - ids and foreign keys. Values that already read as themselves (`roles: ["editor"]`,
`effective_at: "2026-10-01"`) need no entry, and the presenter falls back to the raw value for any key
without one.

Together with the snapshotted actor labels this means a request stays fully readable after both the actor
and the records its payload refers to are gone - worth spelling out in the README, since record-diff gems
render nothing once the record is destroyed.

### 5.8 Lifecycle

```
                    ┌───────────── unapprove (quorum lost) ─────────────┐
                    ▼                                                   │
  (create) ──▶ pending ── quorums ──▶ stage satisfied ──▶ approved ─────┘
                 │ │        met         next stage,          │
                 │ │                    or approved          ├── execute ──▶ executing ──▶ successful ▲ final
                 │ │                                         │                    │
                 │ │                                         │                    └──▶ failed ──┐
                 │ └──── reject ──▶ rejected ▲ final         │                          ▲       │ retry
                 │                                           │                          └───────┘
                 ├──── cancel ──▶ canceled ▲ final ◀─────────┤                          (max_attempts)
                 └──── expire ──▶ expired  ▲ final ◀─────────┘

  pending ──── execute(override: true) ──▶ executing ──▶ successful   (§8.1; sets overridden_at)

  any non-final ── operation undeclared ──▶ canceled ▲ final          (§5.11)
```

`STATUSES = %w(pending approved executing successful failed rejected canceled expired)`
`FINAL_STATUSES = %w(successful rejected canceled expired)`

`executing` (§8) separates "claimed" from "approved". `rejected` is an explicit no, with a mandatory reason,
distinct from "never mind"; one rejection stops the request unless `config.only_record_rejections` (§7.1).

Terminal-state protection lives at the model layer: `before_update` raises `AlreadyFinalized` if `status_was`
was final, so it holds even when a caller bypasses the commands. The transition *into* a final state is
unaffected - `status_was` is the pre-transition value - and appending an `Event` is a different row, so
post-mortem comments on a finished request are untouched (§5.5).

### 5.9 Names and labels

Stage and quorum `name` columns are **declaration identifiers, not display text**: `snake_case`, unique
within their parent, immutable, and carried verbatim into event metadata
(`{ stage: "operational", quorum: "owners" }`) and test matchers (`have_quorum("owners")`). They are stable
across workflow edits in a way `position` is not.

Display text is resolved separately, and is what presenters and views expose:

```
change_requests.stages.<name>     # "Operational review"
change_requests.quorums.<name>    # "Owners"
```

Missing keys fall back to `name.humanize`. `Value::StageProgress` and `Value::Quorum` expose `name` and
`label` as distinct attributes; views render `label`.

A quorum `name` is null when its stage holds exactly one quorum - the `op.approvals` shorthand - because
"which quorum" is then not a meaningful question. The presenter falls back to the stage's label, and event
metadata omits the `quorum` key entirely.

### 5.10 Operation version

Every operation declares `op.version`, a free-form string. It is snapshotted onto the request as
`operation_version` at creation, is `attr_readonly`, and appears in the timeline and in `as_json`.

The gem stores and displays it. There is no comparison, no staleness check and no gating: the value is
whatever the declaring developer wrote, and keeping it truthful is their responsibility.
`ChangeRequests.operations.verify!` requires the attribute to be present and does not judge its content.

The README recommends two conventions:

- **`ENV["GIT_SHA"]`** for applications with frequent releases and high change-request throughput, where the
  useful question is which deployed build a request was raised against.
- **A date string** (`"2026-09-09"`), bumped by hand when the operation's target, payload or workflow
  changes, for applications where operations change rarely and releases are not a useful axis.

### 5.11 Undeclared operations

A request whose `operation_key` is no longer declared (meaning: someone changed or removed the `ChangeRequests.operation`) can never execute - dispatch resolves the operation
live, and the allowlist refuses. Such a request is not partially workable, it is finished:

- **Every guard refuses, except `Comment`.** Approve, unapprove, reject, execute and override all fail with
  `ChangeRequests::UnknownOperation`. Approving something that can never run wastes approver attention and
  writes a misleading audit record. **Commenting stays open**: a request stranded by a removed declaration is
  exactly the one someone needs to leave a note on, and a comment writes no lifecycle state (§5.5). The
  `commented` event records the request's creation-time `operation_version`, there being no live one to read.
- **It is invisible as open work.** `visible_to`, `awaiting_approval_from` and the default index scope all
  exclude requests with no live declaration, so it leaves inboxes and badges immediately, before any
  cleanup runs.
- **`Maintenance.cancel_undeclared!` closes it out**, setting `canceled` with a system actor and emitting
  `operation_undeclared` carrying the operation key and the request's creation-time version.

The cancellation ships as a rake task rather than an automatic sweeper. `canceled` is final, and a missing
declaration is as likely to be a deploy accident - an initializer not loaded, a file renamed - as a
deliberate removal. Refusal and invisibility are immediate and reversible, cancelling all the open change_requests of the removed operation means running the `rake task` to cleanup. Or, if it was a mistake: revert the faulty code change and continue where you left off, without any data loss.

To retire an operation with live requests, deprecate rather than delete: keep the declaration, stop creating
requests against it, and let the outstanding ones drain.

### 5.12 How a request is labelled

There is no per-operation title field and no per-operation locale key. A request identifies itself entirely
from columns it already carries:

- **Operation** - `service` and `method_name`, e.g. `Members::UpdateRoles.call`. Read from the request's own
  columns, so it renders identically for historical requests and for operations no longer declared.
- **Payload preview** - `config.payload_preview_limit` (default 3) payload fields, **ordered
  alphabetically by key**. PostgreSQL `jsonb` does not preserve insertion order, so alphabetical is the only
  ordering that is both deterministic and explicable. Each field renders its `payload_labels` value where
  one was declared, its raw value otherwise.
- **Full payload on demand** - the remaining fields expand in place, a `<details>` element with no
  JavaScript required.

Index rows and the show heading use the same values, so a request reads the same wherever it appears.

Hosts that want different wording override `_operation.html.erb` (§12 Tier 3) rather than declaring
anything per operation.

## 6. Using the gem - a host's walkthrough

> **Everything in this section is code you write or call in your own application.** No gem internals appear
> here. For those, see §5.3 (schema and the inbox query), §7 (guards and commands), §8 (execution and
> override) and §11 (presenters).

The whole surface a host touches is five things: an initializer, a set of operation declarations, one
method to create a request, one command per transition, and one scope to list what is waiting for you.

### 6.1 Install

```bash
bin/rails generate change_requests:install --primary-key-type=uuid --with-specs
bin/rails db:migrate
```

```ruby
# config/routes.rb - only if you want the built-in UI
mount ChangeRequests::Engine, at: "/change_requests"
```

### 6.2 Tell it about your actors

Actor *classes* are registered once; the actor *instance* is passed per request. One class with roles, or
several classes, or a mix - see §9 for the full surface.

```ruby
# config/initializers/change_requests.rb
ChangeRequests.configure do |config|
  config.actor_type "User" do |t|
    t.key_type    = :uuid
    t.label       = ->(user) { user.full_name.presence || user.email }
    t.permissions = ->(user) { user.roles }              # => ["member", "owner", …]
  end

  config.actor_type "Admin" do |t|
    t.key_type    = :integer
    t.label       = ->(admin) { "#{admin.name} (admin)" }
    t.permissions = ->(admin) { admin.roles + %w(admin) }
  end

  config.current_actor = ->(controller) { controller.current_admin || controller.current_user }
end
```

### 6.3 Write the thing that will eventually run

An ordinary service object of your own. The only contract: a **public singleton method taking keyword
arguments**, whose effect is transactional or idempotent.

```ruby
# app/services/members/update_roles.rb
module Members
  class UpdateRoles
    def self.call(member_id:, roles:)
      Member.find(member_id).update!(roles: roles)
    end
  end
end
```

### 6.4 Declare it as an operation

```ruby
# config/initializers/change_requests_operations.rb
ChangeRequests.operations.define "members.update_roles" do |op|
  op.version     = "2026-09-09"                # mandatory - see §5.10

  op.service     = "Members::UpdateRoles"
  op.method_name = :call

  op.approvals permissions: %w(member_admin), required: 2 # who is allowed to approve and how many are necessary?
  
  # Labels will persist, even when the Objects are deleted, to keep a usable audit trail
  # sparse: only keys whose raw value means nothing to a human
  op.payload_labels = ->(p) { { member_id: Member.find_by(id: p[:member_id])&.name } }

  op.idempotent   = true
  op.max_attempts = 3
  op.expires_in   = 7.days
  op.cooldown     = 0                          # minutes a satisfied stage stays reversible - §7.1
end
```

`op.approvals` is the shorthand for the common case - one rule, no ceremony:

```ruby
op.approvals permissions: %w(member_admin), required: 2         # two holders of :member_admin
op.approvals actor_type: "Admin", required: 1                   # one Admin (a class, not a permission)
op.approvals permissions: %w(finance compliance), match: :all, required: 1   # one person holding both
op.approvals eligible_actors: [cfo, general_counsel], required: 2            # only these two people
```

### 6.5 Create a request

Instead of calling `Members::UpdateRoles.call(...)` directly, record the intent:

```ruby
# app/controllers/members_controller.rb
def update_roles
  ChangeRequests.request!(
    "members.update_roles",
    payload:   { member_id: params[:id], roles: params[:roles] },
    requester: current_user,
    tenant:    current_organization                        # optional
  )

  redirect_to change_requests_path, notice: "Submitted for approval"
rescue ChangeRequests::InvalidPayload => e
  redirect_back fallback_location: root_path, alert: e.message
end
```

**The call is identical no matter how elaborate the workflow is** - you never pass thresholds, permissions
or stages. Those live in the operation, are resolved at creation, and are frozen onto the request.

### 6.6 Approve, and execute

Five commands, one shape. Each takes the request and the acting actor, and raises a typed error the
controller can rescue in one place.

```ruby
ChangeRequests::Commands::Approve.call(request:, actor: current_user, comment: "Checked with HR")
ChangeRequests::Commands::Unapprove.call(request:, actor: current_user)
ChangeRequests::Commands::Reject.call(request:, actor: current_user, reason: "Wrong member")
ChangeRequests::Commands::Cancel.call(request:, actor: current_user, reason: "No longer needed")
ChangeRequests::Commands::Comment.call(request:, actor: current_user, body: "Waiting on legal")
ChangeRequests::Commands::Execute.call(request:, actor: current_user)
```

End to end, with the two approvals the operation demanded:

```ruby
request = ChangeRequests.request!("members.update_roles", payload:, requester: alice)
request.status                    # => "pending"

ChangeRequests::Commands::Approve.call(request:, actor: bob)
request.reload.status             # => "pending"   (1 of 2)

ChangeRequests::Commands::Approve.call(request:, actor: carol)
request.reload.status             # => "approved"

ChangeRequests::Commands::Execute.call(request:, actor: carol)
request.reload.status             # => "successful"
Member.find(member_id).roles      # => the new roles - now, and not before
```

Alice cannot approve her own request; that is the point:

```ruby
ChangeRequests::Commands::Approve.call(request:, actor: alice)
# => ChangeRequests::NotApprovable (reason: :requester)
```

If you only need one controller, this is all of it:

```ruby
class ChangeRequestsController < ApplicationController
  rescue_from ChangeRequests::Error, with: ->(e) { redirect_back fallback_location: root_path, alert: e.message }

  def approve
    ChangeRequests::Commands::Approve.call(request: find_request, actor: current_user)
    redirect_to change_requests_path, notice: "Approved"
  end

  private

  def find_request = ChangeRequests::Request.visible_to(current_user).find(params[:id])
end
```

### 6.7 Find what is waiting for me

```ruby
ChangeRequests::Request.awaiting_approval_from(current_user)   # a real, paginatable scope
ChangeRequests::Request.visible_to(current_user).pending
ChangeRequests::Request.where.not(overridden_at: nil)          # the compliance report
current_user.pending_change_request_approvals                  # with `include ChangeRequests::Actor`
```

```erb
<%= link_to "Approvals", change_requests_path %>
<span class="badge"><%= ChangeRequests::Request.awaiting_approval_from(current_user).count %></span>
```

### 6.8 Show it

Either mount the engine and get a working screen, or build your own against the presenter (§12, §13):

```erb
<% presenter = ChangeRequests::RequestPresenter.new(@request, actor: current_user, routes: self) %>

<h1><%= presenter.operation_label %></h1>
<p><%= presenter.payload_preview.map { |f| "#{f.label}: #{f.value}" }.join(" · ") %></p>
<p>Requested by <%= presenter.requester.label %></p>

<% presenter.stages.each do |stage| %>
  <li><%= stage.label %> - <%= stage.satisfied? ? "done" : stage.remaining_options.join(", or ") %></li>
<% end %>

<% presenter.actions.each do |action| %>
  <%= button_to action.label, action.path, disabled: !action.enabled, title: action.reason %>
<% end %>
```

### 6.9 Complex approval workflows

Same declaration, `op.workflow` instead of `op.approvals`. Stages run in order; within a stage, quorums are
independent counting rules that are OR-ed or AND-ed. Four shapes cover essentially every real policy.

**(a) "One Admin OR two Owners"** - alternative routes to the same gate

```ruby
# config/initializers/change_requests_operations.rb
ChangeRequests.operations.define "order.pay" do |op|
  # [...]
  op.workflow do |w|
    w.stage :operational, satisfied_by: :any_quorum do |q|
      q.quorum :admin,  permissions: [{ actor_type: "Admin" }], threshold: 1
      q.quorum :owners, permissions: %w(owner), threshold: 2
    end
  end
end
```

**(b) "One Admin AND two Owners, then a Director"**

```ruby
# config/initializers/change_requests_operations.rb
ChangeRequests.operations.define "contract.sign" do |op|
  # [...]
  op.workflow do |w|
    w.stage :operational, satisfied_by: :all_quorums do |q|
      q.quorum :admin,  permissions: [{ actor_type: "Admin" }], threshold: 1
      q.quorum :owners, permissions: %w(owner), threshold: 2
    end

    w.stage :director, permissions: %w(director), threshold: 1
  end
end
```

One word - `:any_quorum` to `:all_quorums` - is the entire difference between (a) and (b).
An approval counts toward at most one quorum of an `all_quorums` stage, so an Admin who also holds `owner`
cannot close both - this really is three people (§7.1).

**(c) The GitHub shortcut - "two peers, or one admin"**

```ruby
# config/initializers/change_requests_operations.rb
ChangeRequests.operations.define "pull_request.merge" do |op|
  # [...]
  op.workflow do |w|
    w.stage :review, satisfied_by: :any_quorum do |q|
      q.quorum :peers, permissions: %w(member), threshold: 2
      q.quorum :admin, permissions: %w(admin), threshold: 1
    end
  end
end
```

Reach for this when the shortcut genuinely *is* the policy. When it is an exception someone should be
accountable for, use the override in §6.10 instead - it says so far more loudly.

**(d) Everything at once**

```ruby
# config/initializers/change_requests_operations.rb
ChangeRequests.operations.define "budget.approve" do |op|
  # [...]
  op.workflow do |w|
    w.stage :triage, permissions: %w(support), threshold: 1

    w.stage :approval, satisfied_by: :all_quorums do |q|
      q.quorum :risk,  permissions: %w(risk compliance), match: :all, threshold: 1
      q.quorum :money, permissions: %w(finance),                      threshold: 2
      q.quorum :named, eligible_actors: [cfo, general_counsel],       threshold: 2
    end

    w.stage :sign_off, permissions: [{ actor_type: "Director" }], threshold: 1
  end
end
```

Creating and approving is unchanged - only the sequence of people differs:

```ruby
request = ChangeRequests.request!("payouts.release", payload: { payout_id: }, requester: alice)

Approve.call(request:, actor: director_alan)   # => NotApprovable (reason: :stage_not_current)

Approve.call(request:, actor: support_sam)     # stage 1 satisfied
Approve.call(request:, actor: risk_rita)       # risk  ✓
Approve.call(request:, actor: finance_fay)     # money 60% ✓
Approve.call(request:, actor: cfo)             # named ✓ → stage 2 satisfied
Approve.call(request:, actor: director_alan)   # → "approved"

Execute.call(request:, actor: ops_olive)
```

#### Terminology

* **`stage`** = a step, they run sequentially in order
* **`quorum`** = the counting rule inside a step
* **`satisfied_by`** = whether `any_quorum` or `all_quorums` must be met
* **`eligible_actors`** = decide who (actor class or role permissions) may approve
* **`threshold`** = decides how many actors have to approve to permit execution

### 6.10 Break glass

Opt in per action, then pass `override: true` explicitly. Off by default; §8.1 covers what the gem does
with it.

```ruby
op.override permissions: %w(security_officer), require_reason: true
```

```ruby
ChangeRequests::Commands::Execute.call(
  request:, actor: current_admin,
  override: true,
  reason:   "Payment provider outage, CFO approved by phone"
)
```

Audit all ChangeRequests that have been executed before sufficient approvals were given:

```ruby
ChangeRequests::Request.where.not(overridden_at: nil)   # every override, ever
```

### 6.11 Test your operations

```ruby
# spec/change_requests/operations_spec.rb
require "change_requests/rspec"

RSpec.describe ChangeRequests.operations do
  ChangeRequests.operations.keys.each do |key|
    it_behaves_like "a registered change request operation", key
  end
end

RSpec.describe "roles workflow" do
  include_context "with change requests"

  it "needs two approvals" do
    request = ChangeRequests::Testing.build_request(operation_key: "members.update_roles", requester: alice)

    expect(request).to be_approvable_by(bob)
    expect(request).not_to be_approvable_by(alice)

    ChangeRequests::Testing.approve_fully!(request, approvers: [bob, carol])
    expect(request).to have_change_request_status(:approved)
  end
end
```

### 6.12 Why declaring operations is required

Declaring your operations up front is the one thing this gem asks of you that the alternatives do not, so
it is worth saying what it buys:

1. **Dispatch allowlist.** Execution resolves `operation_key → (service, method_name)` from the operation,
   never from the strings stored on the row. Those columns become audit data, not dispatch input, and a request whose
   `operation_key` is no longer declared simply cannot run. `constantize` + `public_send` never sees a
   stored string, so the hole stays closed even if a careless endpoint lets someone write a row.
2. **A stable dispatch target.** `service` and `method_name` are resolved and stored at creation, so what
   a request will invoke is legible from the row itself, not only from live configuration.
3. **Approval policy is policy, not caller input.** Thresholds, permissions and quorum structure come from
   the operation, which is why every `ChangeRequests.request!` call above is identical.
4. **Snapshot-on-create.** The resolved workflow is frozen onto the request and materialised into stages and
   quorums. Editing an operation never retroactively changes an in-flight request, and never leaves one
   wrongly `approved` or wrongly `pending`.
5. **Explicit retryability.** `idempotent` and `max_attempts` are per-action declarations, not an implicit
   "failed requests can be retried forever".
6. **Boot-time verification.** `rake change_requests:verify` (and `to_prepare` in dev/test) asserts every
   service constant resolves, every operation declares a `version`, every quorum declares a positive
   `threshold`, no `all_quorums` stage is unsatisfiable, and no `cooldown` is declared without ActiveJob.
   Verification checks the *singleton* method that dispatch will actually call, so an ordinary
   `def self.call` target is validated against how it is invoked.

**The service contract, documented explicitly** (neither source documented it, and both broke on it):

> A change-request target is a **public singleton method** that accepts **keyword arguments only** and whose
> effect is either transactional or idempotent. It receives `change_request_id:` if it declares that
> keyword - stable across every attempt - which a target calling an external API can pass on as that API's
> idempotency key.

**The payload is untyped.** It is stored as `jsonb` and dispatched as `**payload.symbolize_keys`, so the
host's declared keys become keyword arguments. The gem validates only that it is a JSON object; matching it
to the target's signature is the host's responsibility, and a mismatch surfaces as an `ArgumentError` at
execution, recorded on the attempt and in the `execution_failed` event like any other target failure.

Two consequences worth knowing before writing a payload:

- **Symbolisation is top-level only.** Nested hashes keep string keys, because that is what round-trips
  through `jsonb`. A target taking a nested structure should expect string keys inside it.
- **jsonb normalises.** Key order is not preserved, duplicate keys collapse, and integers, floats, booleans
  and null round-trip as themselves while symbols, dates and times do not - a `Date` goes in and a `String`
  comes out. Serialise deliberately.

Errors a host will actually rescue: `ChangeRequests::UnknownOperation`, `InvalidPayload`, `NotAuthorized`, and
the `TransitionError` family (§8).

## 7. Guards and commands

> **Gem internals.** Nothing here is code a host writes - hosts only *call* the commands, as in §6.6.
> This section is how they are built and why.

**One guard object, consulted by both the command and the presenter**, so a disabled button and a raised
`NotApprovable` cannot disagree.

```ruby
module ChangeRequests
  module Guards
    class Approve < Base
      def allowed?  = reason.nil?
      def reason                      # nil when allowed, an i18n-able symbol/message otherwise
        return :operation_undeclared unless operation                # §5.11, checked in Guards::Base
        return :not_pending      unless request.pending?
        return :requester        if same_person?(request.requester, actor)   # hard-wired; §8
        return :stage_not_current unless stage == request.current_stage
        return :already_decided  if stage.approvals.exists?(approver_type:, approver_id:)
        return :not_permitted    if eligible_quorums.empty?
        nil
      end

      # the quorums of the current stage this actor qualifies for - the same predicate
      # Request.awaiting_approval_from runs in SQL (§5.3)
      def eligible_quorums = stage.quorums.pending.select { authorization.allows?(actor:, quorum: _1) }

      # the subset an approval actually links to: every eligible quorum under any_quorum,
      # the lowest-position one under all_quorums (§5.3)
      def countable_quorums = stage.all_quorums? ? eligible_quorums.first(1) : eligible_quorums

      def check! = allowed? || raise(NotApprovable.new(request:, reason:))
    end
  end
end
```

```ruby
module ChangeRequests
  module Commands
    class Approve < Base
      def call(comment: nil)
        request.with_lock do                       # SELECT … FOR UPDATE
          guard = Guards::Approve.new(request:, actor:)
          guard.check!
          approval = current_stage.approvals.create!(**actor_ref(actor), decision: "approved", comment:)
          approval.quorums = guard.countable_quorums   # one quorum under all_quorums; §5.3
          # emit stamps actor, occurred_at and operation_version (§5.5) on every event
          emit(:approved, metadata: { stage: current_stage.name, quorums: approval.quorums.map(&:name) })
          EvaluateWorkflow.call(request:)          # satisfy quorums → stage → position, maybe → approved
          request
        end
      end
    end
  end
end
```

Commands: `Create`, `Approve`, `Unapprove`, `Reject`, `Execute`, `Cancel`, `Comment`, `Expire`.

Command signature:

```ruby
ChangeRequests::Commands::Approve.call(request:, actor:, comment: nil)
```

**Commands never accept permissions from the caller.** They take an actor; the gem resolves that actor's
permissions through its registered type (§9). A caller-supplied permission set is unverifiable by the gem
and untestable by the host.

**Error taxonomy** (`lib/change_requests/errors.rb`) - so hosts rescue precisely rather than rescuing one
base class and 500-ing on the rest:

```
ChangeRequests::Error
├── ConfigurationError            (no actor types registered, invalid operation)
├── UnknownActorType              (an actor whose class is not registered)
├── UnknownOperation
├── InvalidPayload                (payload is not a JSON object)
├── ReadonlyAttribute             (a creation-time fact was reassigned; §5.1)
├── NotAuthorized
├── TransitionError
│   ├── NotApprovable  ├── NotUnapprovable  ├── NotRejectable
│   ├── NotExecutable  ├── NotCancelable    ├── AlreadyFinalized
│   ├── QuorumNotMet   └── OverrideNotPermitted
├── ExecutionError
│   ├── TargetFailed              (wraps the original; #cause preserved)
│   ├── AttemptsExhausted
│   └── ExecutionInProgress
└── StaleRequest                  (optimistic lock conflict)
```

Every `TransitionError` carries `#request`, `#reason` (a symbol) and a translated `#message`. The engine
controller `rescue_from ChangeRequests::Error` once, and hosts get a flash instead of an exception page.

### 7.1 Workflow evaluation

`ChangeRequests::Commands::EvaluateWorkflow` runs inside the calling command's lock after any decision is
recorded. It is the only code that changes stage or request status as a consequence of approvals. It is a
command like the others - guard, mutate, emit - but an **internal** one: it takes no actor, hosts never call
it, and it is invoked only from `Approve`, `Unapprove` and `Reject`.

```
1. recount every pending quorum of the current stage
      quorum satisfied  ⟺  linked approvals ≥ threshold
2. stage satisfied      ⟺  any_quorum:  at least one quorum satisfied
                           all_quorums: every quorum satisfied
3. satisfied, cooldown == 0  → close_stage! now
   satisfied, cooldown  > 0  → set satisfied_at; enqueue CloseStageJob at satisfied_at + cooldown
   no longer satisfied       → clear satisfied_at; any pending job becomes a no-op
```

`close_stage!` sets `closed_at` and status `closed`, emits `stage_satisfied` naming the quorum that closed
it, then either advances `current_stage_position` to the next stage or - when none remains - sets the
request `approved`.

**Counting.** An approval counts toward a quorum only via its `change_request_approval_quorums` links,
written at decision time and never re-derived. Under `any_quorum` an approval links to every quorum the
actor qualifies for; under `all_quorums` it links to exactly one, the lowest-`position` quorum it qualifies
for, so one person cannot close two quorums that must both be met.

**Closed stages are immutable.** No approval, unapproval or rejection touches a closed stage, and there is
no rollback into an earlier one. Once a stage closes, its outcome is a historical fact.

**Cooldown.** `op.cooldown` (minutes, default `0`) keeps a satisfied stage open instead of closing it
immediately. During the window an approver may still unapprove; if that drops a quorum below threshold the
stage returns to `pending`, `satisfied_at` is cleared, and the request does not advance. A cooldown greater
than zero requires ActiveJob - declaring one without it fails `verify!` with a `ConfigurationError`.

`CloseStageJob` re-evaluates on run rather than trusting its scheduling: it does nothing if the stage is no
longer satisfied, and nothing if it is already closed. Duplicate or late jobs are therefore harmless.

A *lost* job is not harmless - the stage would stay satisfied-but-open forever - so closing does not depend
on the job alone. `Maintenance.close_due_stages!` closes any stage whose `satisfied_at + cooldown` has
passed, on the same schedule as the other sweepers. The job is the fast path; the sweeper is the guarantee.
This is the same pattern as the stuck-execution reaper (§8).

**Unapprove** is permitted only while the actor's own stage is open - `pending`, or `satisfied` inside a
cooldown window. It deletes the actor's approval row and its quorum links, emits `unapproved`, and re-runs
the evaluation above. It is never permitted on a closed stage, on an `approved` request, or in any final
status.

**Rejection is a stop, not a count.** One rejection from any eligible approver or from the requester rejects
the whole request immediately: request status `rejected` (final), the current stage status `rejected`, and a
`rejected` event. A reason is mandatory - `Reject` without one raises. Rejection thresholds are deliberately
not modelled.

`config.only_record_rejections = true` records the decision and the event without short-circuiting: the
workflow continues, and the rejector has spent their decision on that stage and cannot later approve it.

### 7.2 Guard rules

"Eligible approver" means: eligible for at least one quorum on any stage of this request, by permission or
by name (§5.3). It is not restricted to the current stage - a stage-three director may comment on a request
sitting in stage one.

| Command              | Who may                                                       | Permitted when                                                                          | Effect                                             |
|----------------------|---------------------------------------------------------------|-----------------------------------------------------------------------------------------|----------------------------------------------------|
| `Create`             | any actor whose type declares `may_request`                   | operation declared; payload valid                                                       | `pending` request, stages and quorums materialised |
| `Approve`            | eligible approver for a quorum of the current **open** stage  | request `pending`; actor is not the requester; actor has not already decided this stage | approval row + quorum links; `EvaluateWorkflow`    |
| `Unapprove`          | the approver who gave that approval                           | their stage still open (`pending`, or `satisfied` within cooldown)                      | approval and links deleted; `EvaluateWorkflow`     |
| `Reject`             | eligible approver of the current open stage, or the requester | request `pending`; reason present                                                       | request `rejected`, or recorded only (§7.1)        |
| `Cancel`             | the requester, or any eligible approver                       | request not in a final status; reason present                                           | request `canceled`                                 |
| `Comment`            | the requester, or any eligible approver                       | always: final statuses **and** undeclared operations included                           | `commented` event                                  |
| `Execute`            | any actor permitted by the separation-of-duties config        | `approved`, or `failed` and retryable                                                   | §8                                                 |
| `Execute` + override | actor satisfying `op.override` permissions, not the requester | request non-final and not already `executing`; reason present                           | §8.1                                               |
| `Expire`             | system only                                                   | `pending` or `approved` past `expires_at`                                               | request `expired`                                  |

Every guard except `Comment` additionally refuses when the operation is no longer declared (§5.11).

## 8. Execution

> **Gem internals.** Host-facing usage is §6.6 (execute) and §6.10 (override).

Two requirements: a request must never execute twice, and no row lock may be held across the target
invocation. Execution splits into three transactions:

```
T1  with_lock:  Guards::Execute.check!(override:)
                status →executing (conditional UPDATE … WHERE status IN ('approved','failed'),
                                   or WHERE status = 'pending' for an override; §8.1)
                create Attempt(number: attempts.count + 1)  # the unique index is the claim's second lock
                emit(:execution_started)
                COMMIT  ← the claim is now visible to every other process

T2  no lock:    Dispatcher.call(operation_key:, payload:, change_request_id: request.id)
                ← may take seconds, may call an external API, holds no row lock

T3  with_lock:  success → executed_at, executer_id, status=successful, attempt.outcome=succeeded, emit(:executed)
                failure → status=failed, attempt.outcome=failed + error class/message,
                          emit(:execution_failed) carrying the message
```

Zero rows updated by T1's conditional UPDATE means another process claimed it - raise
`ExecutionInProgress`, do not invoke. This is the double-execution fix, and it is stronger than
`with_lock` alone because the claim is *committed* before the side effect runs.

**The failure is recorded outside the rolled-back transaction**, so a target that raises leaves no business
change but does leave a durable record of the failure.

Additional guarantees:

- **Retry ceiling.** `retryable?` is `failed? && operation.idempotent? && attempts.count < max_attempts`.
  A non-idempotent operation is never retryable. There is no counter column - §5.6's rows are the count.
- **Stable identity for the target.** Targets that declare a `change_request_id:` keyword receive
  `request.id`, unchanged across every attempt, so one calling an external API can hand it over as that
  API's idempotency key and a provider that saw a timed-out first call recognises the retry instead of
  charging twice. A per-attempt token would defeat exactly that.
- **Stuck-execution reaper.** `ChangeRequests::Maintenance.reap_stuck_executions!(older_than: 1.hour)`
  moves `executing` rows whose attempt never finished to `failed` with `outcome: abandoned` and a `reaped`
  event. Ship it as a rake task and document scheduling it.
- **Background mode.** `config.execution_mode = :background` makes T2/T3 run in
  `ChangeRequests::Execution::Job`. T1 still commits synchronously, so the UI immediately shows `executing`.
  The job class is only defined when ActiveJob is loaded - no hard dependency.
- **Expiry.** `Maintenance.expire_stale!` moves `pending`/`approved` requests past `expires_at` to `expired`.
- **Undeclared operations.** `Maintenance.cancel_undeclared!` cancels non-final requests whose
  `operation_key` is no longer declared (§5.11).
- **Due stages.** `Maintenance.close_due_stages!` closes satisfied stages whose cooldown has elapsed, so a
  lost `CloseStageJob` cannot strand a request (§7.1).

**Separation of duties** becomes explicit configuration rather than an accident:

```ruby
config.requester_may_approve  = false  # hard-wired false; setting true raises ConfigurationError
config.requester_may_execute  = false  # a choice, not a default assumption
config.approver_may_execute   = true
config.requester_may_override = false  # hard-wired false - see §8.1
```

### 8.1 Override

> **Gem internals.** Host-facing usage - the two lines you actually write - is §6.10.

The deliberate escape hatch, and the one place the gem's central promise is suspended. It exists because
the alternative is worse: without it, a real outage is handled by someone editing the database, which
leaves no record at all.

Off by default, declared per action, separately permissioned, and taken only via an explicit
`override: true`. An actor who could execute normally does so; the override is never reached by accident
and never silently.

**Why this rather than a one-admin quorum.** Both let an admin move a request that lacks its approvals, but
they claim different things. A quorum says *"an admin's approval is sufficient"* - that is the rule, and the
resulting record is an ordinary `approved` request, indistinguishable from any other. An override says
*"two approvals are required and an admin proceeded anyway"* - that is an exception, and it should look
like one. For a gem whose pitch is the four-eyes principle, "the exception is indistinguishable from the
rule" is the wrong default. Use a quorum when the shortcut *is* the policy (§6.9c); use an override when it
is a breach of policy that someone is accountable for.

**What it records.** `overridden_at` on the request makes it a one-column query
(`WHERE overridden_at IS NOT NULL`) and lets the presenter render a badge without loading events. Who and
why live in an `overridden` event emitted **at claim time**, inside T1, carrying the shortfall exactly as it
stood at that moment:

```ruby
kind:     "overridden",
body:     "Payment provider outage, CFO approved by phone",
metadata: { approvals_present: 1, approvals_required: 2,
            incomplete_stages: ["operational"], incomplete_quorums: ["owners"] }
```

Recording it at claim time matters: a later approval must not be able to make an override look
retrospectively unnecessary.

**Guarding it.** `Guards::Execute` gains an override branch - `override_allowed?` requires the action to
declare `op.override`, the actor to satisfy those permissions, and a reason when `require_reason`. The
request must be non-final and not already `executing`. `config.requester_may_override` is hard-wired
`false`: a requester who can override their own request has not been slowed down by the gem at all, which
is a total bypass rather than an exception to the rule.

**Surfacing it.** A separate `Value::Action(name: :execute_override, tone: :danger, confirm: …)`, so it is a
visibly different, always-confirmed button rather than the normal Execute quietly lighting up; the status
pill afterwards carries `tone: :warning` and a tooltip naming the shortfall. `overridden` is the single
event most worth alerting on - the README recommends wiring it to Slack or email on day one, and it is the
worked example in `docs/08_events_and_notifications.md`.

## 9. Authorization and identity

Three distinct concerns, deliberately separated:

1. **Who is the actor?** Actor *classes* are registered up front; the actor *instance* is supplied per
   request. `config.current_actor` (a lambda over the controller) for the UI; an explicit `actor:` argument
   everywhere else. The domain never calls a `current_*` method, and never assumes one actor class.

   ```ruby
   ChangeRequests.configure do |config|
     config.actor_type "User" do |t|
       t.key_type    = :uuid                                    # :uuid | :integer | :string
       t.label       = ->(user) { user.full_name.presence || user.email }
       t.permissions = ->(user) { user.permissions }            # => Array<String>
       t.finder      = ->(ids)  { User.where(id: ids) }         # batch; defaults to Klass.where(id: ids)
       t.path        = ->(user, routes) { routes.admin_user_path(user) }   # optional deep link
       t.may_request = true
       t.may_approve = true                                     # an actor class may request but not approve
       t.may_execute = true
     end

     config.actor_type "Admin"   { |t| t.key_type = :integer; t.label = ->(a) { a.name } }
     config.actor_type "Manager" { |t| … }
   end
   ```

   The registration list is simultaneously: the `*_type` allowlist (§5.7 consequence 5), the label source,
   the permission source, the batch resolver used by `CollectionPresenter`, and the per-type key cast.

   `*_type` stores the actor's **full constant name**, verbatim: `"Admin"` for a top-level class,
   `"Accounts::Admin"` for a namespaced one, and the subclass's own name under STI - `"Manager"`, not
   `"User"`. Each class that can act registers itself; there is no collapsing to a base class, because two
   STI subclasses may need different labels, permissions and key casts.

   Passing an actor is just passing the object:

   ```ruby
   ChangeRequests.request!("members.update_roles", payload:, requester: current_admin)
   ChangeRequests::Commands::Approve.call(request:, actor: current_manager)
   ```

   The type is derived from the object's class and rejected with `ChangeRequests::UnknownActorType` if it
   is not registered - so an unregistered class cannot enter the system through any path.

   **`ChangeRequests::ActorRef`** is what comes back out, and what every presenter and view receives:

   ```ruby
   ref = request.requester     # => ActorRef
   ref.type       # "Admin"
   ref.id         # "42"      (string, as stored)
   ref.label      # live label if the record still exists, else the snapshot
   ref.snapshot   # the label exactly as recorded at write time
   ref.resolved?  # false once the record is gone
   ref.deleted?   # the inverse; drives the "(deleted)" affordance in the UI
   ref.record     # the Admin, or nil - lazily resolved, batch-loaded by CollectionPresenter
   ref.path(routes)
   ```
2. **What may this actor do to this request?** An authorization object, pluggable:

   ```ruby
   config.authorization = ChangeRequests::Authorization::Permissions.new   # default
   # or
   config.authorization = ->(actor:, request:, stage:, action:) {
     Pundit.policy!(actor, request).public_send("#{action}?")
   }
   ```

   The default `Permissions` policy resolves the actor's permission set via that actor type's registered
   `permissions` lambda and checks it against the quorum's permission rows (§5.3) - so `User` and `Admin` can
   derive their permissions completely differently and still be compared against one stage definition.
Both matching semantics ship, but as a **per-quorum** setting rather than an app-wide one, because
   identical rows mean opposite things under each (§5.3). `config.default_permission_match = :any` supplies
   the default and every quorum may override it.

   Because `permission` and `actor_type` are independently nullable, one mechanism covers both shapes of
   app: several actor classes (`Admin`, `Editor`, `Manager`), a single class carrying roles, or a mix of
   the two in one workflow - see the 2×2 in §5.3.

   Named approvers (`change_request_quorum_eligible_actors` rows) are OR-ed with the permission check when
   present - and because both are rows, the same predicate serves the guard *and* the inbox query in §5.3,
   so "the button is enabled" and "it appears in my inbox" cannot drift apart.

3. **Which requests can this actor see?** `config.visible_scope = ->(scope, actor) { … }`, defaulting to
   tenant scoping when `config.tenant_type` is configured, and to `scope` otherwise. Note the scope is
   written against `tenant_type` + `tenant_id` string columns, not an FK. The engine controller applies
   it to **both** `index` and `show`. A request spec asserts a cross-tenant `show` returns 404.

4. **Is this the same human twice?** Optional, off by default. Enforcement keys on
   `(approver_type, approver_id)`, which is airtight inside one actor class but blind across classes - the
   gem cannot know that `Admin#7` and `User#99` are the same person. Hosts that *do* carry a shared
   identity can say so:

   ```ruby
   config.actor_identity = ->(actor) { actor.person_id }   # or email, or the SSO subject
   ```

   The result is snapshotted onto each approval as `approver_identity` (§5.4) and, when configured, used in
   place of `(type, id)` when counting distinct approvers **and** by the requester-cannot-approve rule.
   That second
   use is the important one: without it, requesting as `User#99` and approving as `Admin#7` defeats
   four-eyes silently, which is a worse failure than a miscounted quorum because it is the gem's central
   promise. Unset, behaviour is unchanged and the limitation is documented rather than hidden.

Pundit and ActionPolicy get **documented recipes in `docs/04_authorization.md`, not gem dependencies.**

## 10. Configuration

`ChangeRequests.config` always returns a memoised instance, never `nil`. `configure` mutates in place;
`validate!` runs in `after_initialize` and fails with actionable messages.

```ruby
ChangeRequests.configure do |config|
  # ── identity: register the classes, supply the instance per request ──────
  config.actor_type "User"  do |t|
    t.key_type    = :uuid
    t.label       = ->(user) { user.full_name.presence || user.email }
    t.permissions = ->(user) { user.permissions }
  end
  config.actor_type "Admin" do |t|
    t.key_type    = :integer
    t.label       = ->(admin) { "#{admin.name} (admin)" }
    t.permissions = ->(admin) { admin.roles + %w(admin) }
  end

  config.actor_label_strategy = :live          # :live (default) | :snapshot - see §19.5
  config.current_actor        = ->(controller) { controller.current_admin || controller.current_user }

  # ── tenancy (optional; same type/id/label triple, same absence of FKs) ────
  config.tenant_type "Organization" do |t|
    t.key_type = :uuid
    t.label    = ->(org) { org.name }
  end
  config.tenant_for    = ->(actor) { actor.organization }
  config.visible_scope = ->(scope, actor) {
    scope.where(tenant_type: "Organization", tenant_id: actor.organization_id.to_s)
  }

  # ── authorization ────────────────────────────────────────────────────────
  config.authorization        = ChangeRequests::Authorization::Permissions.new
  config.default_permission_match = :any        # per-quorum override in the operation
  config.actor_identity           = nil         # ->(actor) { actor.person_id } - see §9.4

  # ── separation of duties ─────────────────────────────────────────────────
  config.requester_may_execute  = false
  config.approver_may_execute   = true
  config.requester_may_override = false         # hard-wired; §8.1

  # ── execution ────────────────────────────────────────────────────────────
  config.execution_mode        = :inline        # :inline | :background
  config.job_class             = "ChangeRequests::Execution::Job"
  config.job_queue             = :default
  config.default_max_attempts  = 1
  config.default_expires_in    = nil

  # ── events & notifications ───────────────────────────────────────────────
  config.on_event              = ->(event) { ChangeRequestMailer.notify(event).deliver_later } # called after_commit; see §10
  config.instrument            = true           # ActiveSupport::Notifications "*.change_requests"
  config.only_record_rejections = false         # true = a rejection does not stop the request (§7.1)

  # ── UI (ignored when the engine is not mounted) ──────────────────────────
  config.mount_ui              = true
  config.parent_controller     = "ApplicationController"
  config.layout                = "application"
  config.routes                = %i(index show approve unapprove reject execute cancel comment)
  config.per_page              = 25
  config.filters               = %i(type tenant status stage)   # §12 index filters
  config.payload_preview_limit = 3              # fields shown in an index row - §5.12
  config.stylesheet            = true           # ship the optional CSS
  config.datetime_format       = :short         # I18n.l format key
  config.payload_renderer      = nil            # ->(request, view) { … }
  config.helper_module         = nil            # "MyChangeRequestsHelper"
end
```

Every UI key is inert when `mount_ui` is false, so a headless adopter never has to think about them.

**`config.on_event` is called `after_commit`**, never inside the command's transaction. A notification that
raises must not roll back an approval, and a mailer must not see a row that a later failure will discard.
Hosts are expected to enqueue rather than send inline (`deliver_later`); the gem does not wrap the callback
in a job for them, because queue choice and retry policy belong to the host.

`ActiveSupport::Notifications` instrumentation is emitted from the same place under
`change_requests.<kind>`.

## 11. Presenters

> **Mixed audience.** The presenter *API* below is host-facing - it is what you render against, as in §6.8.
> How it is assembled, and why, is internal.

**Do this even if the gem never ships.** It is the piece that makes the UI testable without rendering, gives
a JSON API for free, fixes the model/service/UI drift, and makes every renderer below it a thin adapter.

```ruby
p = ChangeRequests::RequestPresenter.new(request, actor:, routes: view)

p.operation_label      # "Members::UpdateRoles.call" - from the request's own columns
p.payload_preview      # first N payload fields in schema order, labelled where declared:
                       #   [ Field(key: :member_id, label: "Member", value: "Ada Lovelace"),
                       #     Field(key: :roles,     label: "Roles",  value: "editor") ]
p.payload_fields       # all of them, same shape - the expanded view
p.operation_key        # "members.update_roles"
p.operation_version    # "2026-09-09"
p.requester            # ActorRef - #label, #deleted?, #path; never a raw UUID
p.executer             # ActorRef or nil
p.status               # Value::Status(key: :failed, label: "Failed", tone: :danger,
                       #               tooltip: "Timeout calling provider")
p.stages               # [ Value::StageProgress(name: "operational", label: "Operational review",
                       #       satisfied?: true, current?: false,
                       #       satisfied_by: :all_quorums, satisfied_via: "owners",
                       #       quorums: [ Quorum(name: "admin",  label: "Admins", required: 1, approved: 1,
                       #                         approvers: ["Edith"]),
                       #                  Quorum(name: "owners", label: "Owners", required: 2, approved: 2,
                       #                         approvers: ["Ada","Grace"]) ]),
                       #   Value::StageProgress(name: "director", label: "Director sign-off",
                       #       satisfied?: false, current?: true,
                       #       remaining_options: ["1 from Directors"],
                       #       quorums: [ Quorum(name: nil, label: "Director sign-off",
                       #                         required: 1, approved: 0) ]) ]
p.actions              # [ Value::Action(name: :approve, label: "Approve", enabled: true,
                       #                 reason: nil, method: :post, path: "/change_requests/…/approve",
                       #                 confirm: nil, tone: :primary),
                       #   Value::Action(name: :execute, label: "Execute", enabled: false,
                       #                 reason: "Needs 2 more approvals from Owners, or 1 from Admins"),
                       #   Value::Action(name: :execute_override, label: "Execute without approval",
                       #                 enabled: true, tone: :danger, requires_reason: true,
                       #                 confirm: "This bypasses 2 required approvals. Continue?") ]
p.timeline             # ordered Value::TimelineEntry - one per event row, actor-labelled, i18n'd
p.payload_fields       # honours config.payload_renderer when set
p.as_json              # every value above, as a Hash
```

Key properties:

- **`actions` is computed from the same `Guards::*` objects the commands enforce with.** A disabled button
  and a raised `NotApprovable` can never disagree, and the `reason` shown in the tooltip is the same reason
  the command would have raised.
- **`CollectionPresenter` owns eager loading**, so the N+1 is fixed once. It preloads
  `stages: :approvals` and `events`, then collects every `ActorRef` on the page, **groups them by
  `actor_type`, and issues one query per type** through that type's registered `finder` - three actor
  classes on a page of 25 requests costs three queries, not seventy-five. Never `find_by` per row.
- **Actor resolution is optional, not required.** Every label is already on the row, so a presenter
  constructed with `resolve_actors: false` renders a complete page with **zero** queries against host
  tables. That is the fast path for large index pages, and the only path once an actor class has been
  removed from the app entirely.
- **Deleted actors degrade, never raise.** `ActorRef#label` falls back to the snapshot and `#deleted?`
  becomes true, so `_actor.html.erb` renders "Ada Lovelace (deleted)" with no link. A view spec asserts
  exactly this against a request whose actor row has been hard-deleted.
- **An OR-stage renders honestly.** `remaining_options` turns a half-satisfied `any_quorum` stage into
  "2 more from Owners, **or** 1 from Admins" rather than a single misleading "1/2" - the one place a naive
  progress bar actively lies to the reader.
- **No ActionView dependency.** `routes:` is an optional injected url-helper object; when absent, `path` is
  nil and `as_json` still works. This keeps presenters in the domain core, usable from a host's own API
  controller or a background job.
- **`as_json` is the documented public contract**, written out in `docs/06_views_and_theming.md`. Any
  alternative front end - Hotwire, React, Phlex, Avo - targets it.

## 12. Views

Three customisations account for nearly all view changes a host wants: render an actor instead of an ID,
format a timestamp, render the payload. The design makes those three require **zero files**, and treats
ejecting partials as a last resort rather than the first step - an ejected file stops receiving upstream
fixes.

### Tier 0 - Headless

`config.mount_ui = false`. No controllers, no views, no routes. Presenters and `as_json` are still available.
The gem stands alone as a domain + API layer. A meaningful share of adopters - anyone with a design system,
anyone on Avo or Administrate - wants exactly this.

### Tier 1 - Drop-in UI

```ruby
mount ChangeRequests::Engine, at: "/change_requests"
```

A working index (filter, sort, paginate) and show page (timeline, stage progress, payload, actions), in
plain ERB, in the host's own layout, using the host's `ApplicationController` as the parent so the host's
`before_action :authenticate!` applies automatically. Progressive enhancement only:

- `button_to` forms that work with JavaScript disabled.
- `turbo_stream` responses *only* when `turbo-rails` is defined; HTML redirect otherwise.
- Two optional Stimulus controllers (clipboard, relative time) shipped as importmap-pinnable assets, each
  with a server-rendered fallback: `I18n.l` server-side, client enhancement on top.
- No Tailwind, DaisyUI or Bootstrap class names - a framework's class names bind the gem to one host's
  design system.

**Index filters.** `config.filters` selects which appear; all combine, all are `GET` query parameters, and
each maps to a scope on `ChangeRequests::Request`:

| Param    | Values                                       | Scope                                                     |
|----------|----------------------------------------------|-----------------------------------------------------------|
| `type`   | an `operation_key`, or `Service.method_name` | `where(operation_key:)` / `where(service:, method_name:)` |
| `tenant` | `Type:id`                                    | `where(tenant_type:, tenant_id:)`                         |
| `status` | one or more of `STATUSES`                    | `where(status:)`                                          |
| `stage`  | a stage `name`                               | joins the current stage on `name`                         |

Unknown params are ignored rather than raising, so a stale bookmark degrades to an unfiltered list. Sorting
is `created_at DESC` by default with `updated_at` and `expires_at` as alternatives; paging is
`config.per_page`.

### Tier 2 - Theme without touching markup

**A documented CSS class contract.** Semantic, prefixed, BEM-ish:

```
.cr-table  .cr-row  .cr-row--failed
.cr-status  .cr-status--pending  .cr-status--approved  .cr-status--executing  .cr-status--failed
.cr-stage  .cr-stage--current  .cr-stage--satisfied  .cr-stage__count
.cr-btn  .cr-btn--approve  .cr-btn--execute  .cr-btn--reject  .cr-btn--disabled
.cr-timeline  .cr-timeline__entry  .cr-timeline__entry--execution_failed
```

An **opt-in** stylesheet (`config.stylesheet = true`, ~150 lines) built entirely on CSS custom properties, so
a host restyles it with a handful of variable overrides and no `!important`:

```css
:root { --cr-color-danger: #b00020; --cr-radius: 6px; --cr-font: inherit; }
```

**Three configuration seams**, covering the three customisations named above:

```ruby
config.actor_type "User" { |t| t.label = ->(u) { u.display_name }
                                t.path  = ->(u, routes) { routes.admin_user_path(u) } }
config.datetime_format   = :long             # or ->(time) { time_ago_in_words(time) }
config.payload_renderer  = ->(request, view) { view.render "admin/payload", request: }
```

Actor rendering is per type rather than one global lambda, so a `User` and an `Admin` render differently.

**All strings through I18n**, defaults in `config/locales/en.yml`, every key namespaced under
`change_requests.*`. Statuses, action labels, guard reasons, confirmations, empty states, plus
`change_requests.stages.<name>` and `change_requests.quorums.<name>` (§5.9).

### Tier 3 - Override one partial

Rails searches the host's view paths before the engine's. A file at
`app/views/change_requests/requests/_row.html.erb` in the host replaces exactly that partial. Nothing else is
forked; every other partial keeps receiving upstream fixes.

This only works if the partial inventory and its locals are a **documented, semver-covered contract**. That
document is the single most valuable piece of view support in the plan:

| Partial                     | Locals                                  | Purpose                                       |
|-----------------------------|-----------------------------------------|-----------------------------------------------|
| `index.html.erb`            | `collection:` (CollectionPresenter)     | page shell                                    |
| `_filters.html.erb`         | `filters:`, `url:`                      | status / operation / requester filters        |
| `_table.html.erb`           | `collection:`                           | `<thead>` + one `<tr>` per row                |
| `_row.html.erb`             | `request:` (RequestPresenter)           | one request                                   |
| `_status.html.erb`          | `status:` (Value::Status)               | the pill                                      |
| `_stage_progress.html.erb`  | `stages:` (Array<Value::StageProgress>) | "1/1 admin - 2/2 owners → director"           |
| `_quorum.html.erb`          | `quorum:` (Value::Quorum)               | one counting rule inside a stage              |
| `_override_form.html.erb`   | `request:`, `url:`                      | the danger path; reason field (§8.1)          |
| `_actions.html.erb`         | `actions:` (Array<Value::Action>)       | the button group                              |
| `_action_button.html.erb`   | `action:`                               | one button, enabled or disabled-with-reason   |
| `show.html.erb`             | `request:`                              | detail page shell                             |
| `_operation.html.erb`       | `label:`                                | `Service.method_name`; the wording seam       |
| `_payload_preview.html.erb` | `fields:` (Array<Value::Field>)         | the first N fields, for an index row          |
| `_payload.html.erb`         | `fields:` (Array<Value::Field>)         | full payload, in a `<details>` expander       |
| `_timeline.html.erb`        | `entries:`                              | the audit trail                               |
| `_timeline_entry.html.erb`  | `entry:`                                | one event                                     |
| `_comment_form.html.erb`    | `request:`, `url:`                      | add a comment                                 |
| `_actor.html.erb`           | `actor:` (ActorRef, or nil)             | actor seam; handles deleted and system actors |
| `_datetime.html.erb`        | `time:`, `format:`                      | timestamp seam                                |
| `_empty.html.erb`           | -                                       | empty state                                   |

Every partial takes **presenter objects or value objects, never ActiveRecord models**. That is what makes the
contract stable: the gem can restructure its schema without breaking a host's overridden partial.

A parallel seam exists in Ruby: `ChangeRequests::RequestsHelper` methods are all small and overridable via
`config.helper_module = "MyChangeRequestsHelper"`, which is prepended.

### Tier 4 - Eject some or all views

```
rails g change_requests:views                       # all of them
rails g change_requests:views --only=row,status     # just these two
rails g change_requests:views --list                # print the inventory + locals
```

Documented as the **escape hatch**, with an explicit warning in the generator output that ejected files no
longer receive upstream changes, and a pointer back to Tier 2/3.

### Tier 5 - Generate views into your own app

```
rails g change_requests:scaffold_ui --namespace=admin --parent=Admin::BaseController --layout=admin
```

Writes `app/controllers/admin/change_requests_controller.rb` and `app/views/admin/change_requests/*.html.erb`
into the **host's** namespace, using the host's layout and route helpers, built against the presenter API.
The engine is then never mounted. This is the honest answer for teams whose approvals screen must live
inside an existing admin area with its own navigation, breadcrumbs and design system - which, in practice, is
most teams with an opinion about their UI.

### Tier 6 - Build your own front end

`RequestPresenter#as_json` is the contract for a Hotwire, React or mobile front end - the host serves it
from its own controller. `docs/06_views_and_theming.md` documents the JSON schema and shows a ~60-line Phlex
component set written against the presenter, as a worked example: alternative renderers are cheap *because*
the logic is in the presenter, and no Phlex dependency ships.

**Explicitly deferred:** an HTTP API controller in the gem, and `change_requests-phlex` /
`change_requests-view_component` satellite gems. One maintainer, one renderer.

### Verifying custom views

Ship shared examples so ejected and hand-written views stay honest (§15):

```ruby
it_behaves_like "a change requests index view", path: admin_change_requests_path
it_behaves_like "a change requests row partial", partial: "admin/change_requests/row"
```

These assert the class contract, that disabled actions render their reason, that no raw UUID leaks where an
actor label belongs, and that every action button is a real form. A host that ejects views gets a regression
suite for free.

## 13. Generators and templates

| Generator                                   | Produces                                                                                       |
|---------------------------------------------|------------------------------------------------------------------------------------------------|
| `change_requests:install`                   | initializer, operations initializer, migrations, optional spec-support file, README next-steps |
| `change_requests:operation NAME`            | an operation stub + a target service stub + its spec                                           |
| `change_requests:controller`                | a subclass of `ChangeRequests::RequestsController` for host overrides                          |
| `change_requests:views [--only] [--list]`   | ejects ERB partials                                                                            |
| `change_requests:scaffold_ui [--namespace]` | host-namespaced controller + views                                                             |
| `change_requests:migration_upgrade`         | schema migrations between gem majors                                                           |

Install generator options:
`--primary-key-type=uuid --actor-types=User,Admin --tenant-types=Organization --skip-tenant
 --with-specs --mount-at=/change_requests`

`--primary-key-type` governs the gem's **own** primary keys only. The generator asks nothing about the
host's actor tables and writes no reference to them: `--actor-types` merely pre-fills the initializer's
`config.actor_type` blocks as commented stubs, and passing nothing is fine - the schema is identical either
way. Adding a fourth actor class later is an initializer edit, never a migration.

Templates shipped (`lib/generators/change_requests/*/templates/`):

- `initializer.rb.tt` - every config key, commented, with the chosen actor/tenant filled in
- `operations.rb.tt` - one worked example action, commented
- `create_change_requests.rb.tt` - all five tables, FKs **between the gem's own tables only**, CHECK
  constraints, composite `(type, id)` indexes on every actor reference, partial indexes; correct PK type
- `controller.rb.tt` - subclass stub showing how to override `find_requests`, `actor`, `after_command`
- `spec_support.rb.tt` - `require "change_requests/rspec"` + config for the host suite (§15)
- `en.yml.tt` - a copy of the gem's locale file for hosts that want to edit rather than override
- `_*.html.erb` - the ERB partial set (for the views generator)
- `action.rb.tt` / `action_spec.rb.tt` - a service stub with the correct singleton-keyword-argument shape,
  and a spec that already includes `it_behaves_like "a registered change request operation"`

**Packaging requirement:** every generator's `source_root` must resolve against files actually included in
`spec.files`. A `path:` dependency during development hides omissions that break the packaged gem;
`spec/integration/packaging_spec.rb` (§15.4) asserts it.

## 14. Test kit for host apps

Adopters must be able to test *their* actions and *their* views. Ship a first-class test kit - this is a
genuine differentiator, and it is cheap once presenters and guards exist.

```ruby
# spec/rails_helper.rb (or the file the install generator writes)
require "change_requests/rspec"
```

### 14.1 Shared contexts

```ruby
include_context "with change requests"            # config isolation, operation sandbox, cleanup
include_context "with an approved change request" # fast-forwards a request past its whole workflow
```

### 14.2 Operation sandboxing

```ruby
ChangeRequests::Testing.operations_sandbox do |operations|
  operations.define("test.noop") do |op|
    op.service     = "TestTarget"
    op.method_name = :call
    op.version     = "2026-09-09"
    op.approvals permissions: %w(admin), required: 1
  end
end                                                # original operations restored afterwards
```

Prevents host specs from mutating the real operations, and lets domain specs run without the host's.

### 14.3 Builders (no FactoryBot required)

```ruby
ChangeRequests::Testing.build_request(operation_key: "test.noop", requester: user, payload: {})
ChangeRequests::Testing.actor_type_sandbox { |c| c.actor_type("TestActor") { |t| … } }
ChangeRequests::Testing.orphan_actors!(request)   # hard-deletes the actor rows, keeps the snapshots
ChangeRequests::Testing.approve_fully!(request, approvers: [alice, bob])   # satisfies every stage
ChangeRequests::Testing.advance_to(request, :approved)                     # any reachable status
ChangeRequests::Testing.execute!(request, actor: carol)
```

Optional FactoryBot definitions in `lib/change_requests/factories.rb`, loaded only if the host opts in via
`FactoryBot.definition_file_paths << ChangeRequests.factories_path`.

### 14.4 Matchers

```ruby
expect(request).to be_approvable_by(alice)
expect(request).not_to be_executable_by(bob)
expect(request).to have_change_request_status(:approved)
expect(request).to have_stage(:owner).with_approvals(2)
expect(request.requester).to be_deleted_actor.with_label("Ada Lovelace")
expect(request).to be_awaiting_approval_from(editor)      # inbox and guard, asserted together
expect(request).to have_quorum("owners").with_approvals(2)
expect { override }.to emit_change_request_event(:overridden).with_metadata(approvals_required: 2)
expect(ChangeRequests.config).to have_registered_actor_type("Admin")
expect { command }.to emit_change_request_event(:executed).with_actor(carol)
expect { command }.to change_request_status_from(:approved).to(:successful)
expect(presenter.actions).to include_enabled_action(:approve)
expect(ChangeRequests.operations).to have_registered_operation("members.update_roles")
```

### 14.5 Shared examples

```ruby
# In the host app, once per declared operation. Proves they are sound before production does.
RSpec.describe "members.update_roles" do
  it_behaves_like "a registered change request operation", "members.update_roles"
end
```

That shared example asserts: the service constant resolves; the action is a public singleton method; every
declared permissions are Strings that at least one registered actor type's `permissions` lambda can
actually produce; `idempotent`/`max_attempts` are coherent (a
non-idempotent action may not declare `max_attempts > 1`); and, if the action declares
`change_request_id:`, that the method accepts it.

Also shipped:

- `"a guarded change request command"` - for hosts writing custom commands
- `"a change requests index view"`, `"a change requests row partial"` - the view contract (§13)
- `"an idempotent change request target"` - runs the target twice with the same `change_request_id` and
  asserts a single effect; hosts include it in their own service specs
- `"a registered actor type"` - asserts the class resolves, `key_type` matches its actual primary key,
  `label` returns a non-blank String for a persisted instance, `permissions` returns an Array of Strings,
  and the batch `finder` returns the same records as `where(id:)`. Hosts run it once per registered type;
  it is what catches a `key_type` mismatch before ids silently fail to resolve.
- `"a change request view that survives a deleted actor"` - builds a request, orphans its actors, renders,
  and asserts the page still renders with the snapshot label and no query against the host table

### 14.6 Test-mode toggles

```ruby
ChangeRequests::Testing.inline_execution!    # force :inline even when config is :background
ChangeRequests::Testing.freeze_operations!     # raise on any mutation after boot (CI safety)
ChangeRequests::Testing.capture_events { … } # => Array<Event>, without hitting config.on_event
```

## 15. The gem's own test suite

### 15.1 Dummy app (`spec/dummy`)

A real Rails app on PostgreSQL, with:

- Three registered actor types in one app, deliberately heterogeneous: `User` (uuid PK), `Admin`
  (bigint PK) and `Manager` (string PK) - the configuration the schema exists to support, exercised by
  every request spec rather than by a separate fixture
- `Organization` as the tenant type
- A spec that hard-deletes an `Admin` and asserts every historical request still renders, still exports to
  JSON, and still executes
- Three demo targets: `Demo::UpdateRoles` (transactional, idempotent), `Demo::ChargeCard` (external,
  non-idempotent, honours `change_request_id:`), `Demo::Explode` (always raises)
- Seeds covering every status and a two-stage workflow

`bin/demo` boots it on `localhost:3000` with seeds. This is the view-development harness and the source of
the README screenshots. It costs nothing extra and pays for itself the first afternoon spent on CSS.

### 15.2 Coverage targets

Required areas:

- models (validations, terminal-state guard, readonly attributes raising rather than silently discarding,
  event immutability against **both** update and destroy, table names derived from the prefix)
- operations (verification, materialise-on-create, unknown-operation rejection, non-object payload rejected)
- guards (a truth table per guard × status × actor role - table-driven, one `where` per row)
- commands (happy path, every guard rejection, event emission, workflow advancement)
- workflow evaluation, §7.1 in full: quorum satisfaction, `any_quorum` / `all_quorums`, one-quorum-per-
  approval under `all_quorums`, stage closing with and without a cooldown, unapproval during the cooldown
  window, refusal after closing, `close_due_stages!` closing a stage whose job never ran, rejection
  short-circuiting, `only_record_rejections` - plus each of the four §6.9 shapes end-to-end, since those
  are the examples in the docs and must not rot
- names and labels (uniqueness within parent; i18n resolution with `humanize` fallback; null quorum name
  falling back to the stage label and omitting the event metadata key)
- request labelling (payload preview honouring schema declaration order and `payload_preview_limit`;
  sparse `payload_labels` falling back to raw values; labels rendering for an undeclared operation)
- event `operation_version` (stamped from the live declaration; diverging from the request's creation-time
  value after a declaration change)
- undeclared operations (every guard refuses; the request is absent from `visible_to` and
  `awaiting_approval_from`; `cancel_undeclared!` cancels it and emits `operation_undeclared`)
- eligibility (the full 2×2 of nullable `permission` × `actor_type`, under both `match` modes, across all
  three dummy actor classes; the CHECK rejecting a doubly-NULL row; named approvers OR-ed in) - and a spec
  asserting `Guards::Approve` and `Request.awaiting_approval_from` agree on every cell, since that
  agreement is the whole reason eligibility is rows
- execution (success, target raises, retry ceiling, non-idempotent refusal, `change_request_id` propagation, reaper)
- override (refused when the action declares none; refused for the requester; refused without a reason when
  required; `overridden_at` set; the `overridden` event's shortfall snapshot matching the state *at claim
  time* and not being rewritten by a later approval)
- presenters (actions match guards for every status × actor combination; `as_json` key set and value types)
- controllers/routes (opt-in route list, tenant scoping on **index and show**, error taxonomy → flash,
  Turbo and non-Turbo responses)
- views (rendering, class contract, disabled-reason rendering, no raw UUIDs)
- generators (`Rails::Generators::TestCase` for all six; assert generated migrations actually run)
- configuration (`validate!` messages; defaults; `config` never nil)

### 15.3 Concurrency specs

Real threads, real connections, real PostgreSQL:

```ruby
it "executes exactly once under concurrent execute" do
  request = approved_request
  results = ChangeRequests::Testing.in_parallel(4) { Commands::Execute.call(request:, actor:) rescue $! }
  expect(Demo::ChargeCard.invocations).to eq(1)
  expect(results.count { _1.is_a?(ChangeRequests::ExecutionInProgress) }).to eq(3)
  expect(request.reload).to be_successful
end
```

Plus: concurrent approvals racing on the last slot of a quorum (exactly one triggers the transition);
concurrent approve + unapprove (final state is consistent with the approval count);
approve twice from the same actor (`RecordNotUnique` is caught and surfaced as `NotApprovable`, not a 500).

### 15.4 Packaging spec

```ruby
it "packages every directory the generators and engine need" do
  files = Gem::Specification.load("change_requests.gemspec").files
  %w(app/views app/controllers config/routes.rb config/locales lib/generators).each do |dir|
    expect(files.grep(/\A#{dir}/)).not_to be_empty, "#{dir} missing from spec.files"
  end
end
it "resolves every generator source_root against packaged files" do … end
```

### 15.5 Headless spec

```ruby
# Run in a subprocess with Rails never required.
it "loads and operates the domain core without Rails" do
  out = `ruby -Ilib spec/integration/headless_script.rb`   # AR connection, migrate, create, approve, execute
  expect(out).to include("successful")
end
```

Plus a static check that no file under the domain directories mentions `ActionController|ActionView|Rails\.`.

### 15.6 CI matrix

- Ruby: `4.0` _(older versions might be tested when requested)_
- Rails: `8.1` via `gemfiles/*.gemfile` + `BUNDLE_GEMFILE` _(older versions might be tested when requested)_
- PostgreSQL: `18` service containers _(older DBs might be supported when requested)_
- Jobs: `rubocop`, `rspec` (matrix), `bundle:audit`, `headless`, `packaging`, `generators-on-a-real-app`
  (generate a throwaway Rails app, run `change_requests:install`, run the migrations, boot it - the test
  that catches everything the dummy app's `path:` dependency hides)

## 16. Feature list for 1.0

**Core**

- Deferred, persisted, replayable invocation of a declared operation
- Operations: dispatch allowlist, declared version, payload labels, approval policy,
  retry policy,
  override policy, boot-time verification
- Sequential stages of AND/OR-ed quorums, each quorum a threshold count; per-quorum permission matching
- Eligibility by permission x actor type, or by named approver
- Optional per-operation `cooldown` keeping a satisfied stage reversible for a configurable window
- Separation of duties: requester cannot approve; execute and override configurable
- Approval withdrawal, with demotion when a quorum is lost
- Rejection with a mandatory reason, stopping the request by default or recorded only
- Stage closing: a satisfied stage becomes immutable, with no rollback into earlier stages
- Terminal-state protection at the model layer
- Undeclared operations refused by every guard, hidden from open work, closed out by a rake task
- Append-only `change_request_events` audit trail with actor attribution and typed kinds
- Snapshotted labels (`requester_label`, `payload_labels`) that survive deletion of the actor or the
  referenced record
- Polymorphic actors chosen per request, no foreign keys to host tables, several actor classes in one app
- Optional `config.actor_identity` for cross-class identity

**Execution**

- Claim-then-invoke: conditional UPDATE committed before the side effect, no row lock held across I/O
- `executing` status, attempts table, retry ceiling, stable `change_request_id` handed to the target
- Background execution via ActiveJob (optional dependency)
- Stuck-execution reaper, expiry sweeper
- Override with reason, `overridden_at`, and an `overridden` event carrying the shortfall at claim time

**Surface**

- Guards shared by commands and presenters; typed error taxonomy
- Presenters + a versioned `as_json` contract
- `Request.awaiting_approval_from(actor)` - the approver inbox as an indexed, paginatable scope
- ERB views with a documented locals contract and six escalating override tiers
- Pagination, filtering, sorting; I18n throughout; optional stylesheet
- Authorization adapter; visibility scoping applied to index and show
- Notifications via `config.on_event` and `ActiveSupport::Notifications`
- Six generators; host test kit; maintenance rake tasks

**Deliberately post-1.0**

Delegation / proxy approval - escalation and reminder schedules - conditional routing rules ("> EUR 10k
needs two approvals") - weighted or per-group quorum - arbitrary nesting of quorum groups - request
templates / bulk approval - a transactional outbox beyond the attempts table - non-PostgreSQL adapters ·
Phlex and ViewComponent renderer gems - an admin dashboard with metrics.

## 17. Milestones

Sequenced so that each milestone is independently releasable and the risky work lands early. Larger
milestones are split into parts that can be picked up separately. **Spec** names the sections that define
the work; a part with no gap listed in §17.1 is ready to be broken into tickets from those sections alone.
Estimates assume one experienced developer working from this plan.

| #       | Version   | Scope                                                                                                                                                                                                                      | Spec        | Effort |
|---------|-----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------|--------|
| **M0**  | 0.1.0     | Engine skeleton, Zeitwerk, `Configuration` + `validate!`, gemspec deps, dummy app, CI matrix, `rake ci`, headless + packaging specs. **Not started**: only `bundle gem` output and `rake ci` exist                         | §1, §2, §15 | 5 d    |
| **M1a** |           | Migrations for all nine tables, **written as the install-generator template**, models, indexes, CHECK constraints, readonly attrs, terminal-state guard, event immutability                                                | §4, §5      | 7 d    |
| **M1b** | 0.2.0     | Guards for the whole §7.2 table, and commands for all of it **except `Execute`**; a minimal `Operations`/`Operation` pulled forward from M2; `with_lock`; sequential multi-stage, single-quorum evaluation; error taxonomy | §7          | 11 d   |
| **M2**  | 0.3.0     | Operations, completed: the full `op.workflow` DSL, `op.cooldown`, `verify!`, `ChangeRequests.request!`, `rake change_requests:verify`. Registry, `op.approvals` and materialise-on-create land early, in M1b               | §6.4, §6.12 | 2–3 d  |
| **M3a** |           | `Commands::Execute` and claim-then-invoke: `executing`, attempt rows, conditional UPDATE, retry ceiling, the §8.1 override branch. **Concurrency specs.** `Guards::Execute` lands in M1b                                   | §8, §15.3   | 3 d    |
| **M3b** | 0.4.0     | Background execution job, stuck-execution reaper, expiry sweeper, `cancel_undeclared!`, rake tasks                                                                                                                         | §8, §5.11   | 2 d    |
| **M4**  | 0.5.0     | Actor-type registration, `ActorRef`, batch resolution, label snapshots, authorization adapter, `visible_scope`, tenancy, separation-of-duties flags, `ChangeRequests::Actor`                                               | §9          | 2–3 d  |
| **M5**  | 0.6.0     | Presenters, value objects, collection eager loading, `as_json`                                                                                                                                                             | §11         | 3 d    |
| **M6a** |           | Base + requests controllers, routes, `rescue_from`, `visible_to` on index **and** show, index page with filters, sorting, pagination                                                                                       | §12 Tier 1  | 3 d    |
| **M6b** |           | Show page: stage/quorum progress, payload preview and expander, timeline, action buttons, override form                                                                                                                    | §12 Tier 3  | 2–3 d  |
| **M6c** | 0.7.0     | i18n, optional stylesheet, CSS class contract, Turbo-optional responses, Stimulus fallbacks, `bin/demo`, view + request specs                                                                                              | §12 Tier 2  | 2–3 d  |
| **M7**  | 0.8.0     | Generators (install, operation, controller, views, scaffold_ui) + generator specs + generate-on-a-real-app CI job                                                                                                          | §13         | 4 d    |
| **M8**  | 0.9.0     | Host test kit: `change_requests/rspec`, `Testing`, matchers, shared examples, factories, `docs/07_testing.md`                                                                                                              | §14         | 3–4 d  |
| **M9a** |           | Multi-quorum evaluation: `all_quorums`, one-quorum-per-approval linking, named approvers. `any_quorum`, sequential stage advance and stage closing land in M1b                                                             | §7.1        | 2–3 d  |
| **M9b** |           | `op.cooldown`: `CloseStageJob`, unapproval inside the window, `close_due_stages!` fallback                                                                                                                                 | §7.1        | 1–2 d  |
| **M9c** | 0.10.0    | `awaiting_approval_from` inbox scope, guard/scope equivalence spec, UI stage and quorum progress                                                                                                                           | §5.3, §11   | 2 d    |
| **M10** | 0.11.0    | Notifications (`on_event` after_commit, `ActiveSupport::Notifications`), maintenance rake tasks                                                                                                                            | §10         | 2–3 d  |
| **M11** | **1.0.0** | Docs set, README with screenshots, CHANGELOG, semver policy, RBS in `sig/`, release                                                                                                                                        | -           | 4–5 d  |

**Total: roughly 10-12 focused weeks**, or 5-6 months at one day a week.
M0 through M1b alone is ~23 days: M1 carries the schema, which is the work that is cheapest to do once and
most expensive to redo.

M9 lands late although the **schema supports it from M1a**: the tables are cheap up front and expensive to
retrofit, while the multi-quorum evaluation logic and its UI can wait until the single-quorum path is
exercised. M1b does ship the sequential stage advance, because that is `position + 1` and deferring it would
mean rewriting `EvaluateWorkflow` in M9a rather than extending it.

### 17.1 Gaps to close before ticketing those parts

Everything else in the table is specified well enough that tickets can be written from the referenced
sections. These six are not, and each needs a decision rather than more prose:

| Part    | What is missing                                                                                                                                            |
|---------|------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **M2**  | What `verify!` prints when it fails - one line per problem, or one raised error listing all of them.                                                       |
| **M5**  | `as_json` is called a documented, versioned contract but its keys and value types are never written out.                                                   |
| **M6b** | The show page has an inventory of partials but no layout: what appears, in what order, and what an empty timeline or a nil executer renders.               |
| **M7**  | `scaffold_ui` output is one line. Which files, in which namespace, with which route helpers and layout assumptions.                                        |
| **M10** | The object handed to `config.on_event` is unspecified - the `Event` record, a value object, or a payload hash, and which associations are preloaded on it. |
| **M4**  | `key_type` casting rules: what `:string` means for a non-integer, non-uuid PK, and what `finder` is expected to return for ids that no longer resolve.     |

## 18. Cut line for 1.0

**In:** operations, staged schema, events, `rejected`, execution safety, presenters, ERB UI with the six-tier
override story, generators, host test kit, PostgreSQL-only, Rails 7.1–8.1.

**On other databases:** nothing ships and nothing is prepared - no adapter branches, no compatibility
layer, no second CI target. The only concession is the schema posture in §5.7, which costs nothing today and
keeps a future port from being a data migration.

**Out, and say so plainly in the README:** typed payload validation, delegation, escalation/reminders, a
conditional-routing rules
engine, weighted quorum, bulk approval, non-PostgreSQL adapters, Phlex/ViewComponent satellites, an admin
dashboard, a full transactional outbox.

The non-goals list ships in the README: it tells an evaluator in ninety seconds whether the gem fits.

## 19. 0.x Decisions

1. **Minimum Ruby:** The skeleton declares `required_ruby_version >= 4.0.0` and pins `.ruby-version` to
   4.0.6. _(older versions might be supported when requested)_
2. **Minimum Rails:** 8.1  _(older versions might be supported when requested)_
3. **Commands raise** like in `update!` and are handled with `rescue_from` in the controller. Revisit if a real adopter wants Results; adding `Commands::Approve.result(...)` later is
   additive and non-breaking.
4. **Any actor whose type declares `may_request` may request any declared operation.** The approval gate is
   the control, and over-restricting creation makes the feature unusable. Which actions a given person may
   trigger is the host application's own authorization question, answered before `ChangeRequests.request!`
   is ever called.
5. **Label freshness:** `:live` as default, with `:snapshot`as fall back.
6. **No memoizing and not state for `ActorRef#record`**
7. **The override requires only one person.**
8. **Gem name availability** `change_requests` - has been reserved on RubyGems by releasing a first version without implementation.
9. **A minimal `Operations`/`Operation` ships in M1b, not M2.** Every guard checks that the operation is
   still declared (§5.11) and `Create` cannot write `service`, `method_name` or `operation_version` without
   a registry. M1b gets `define`/`[]`/`keys`, those attributes, and the `op.approvals` shorthand; M2 adds
   the full `op.workflow` DSL, `op.cooldown`, `verify!` and `ChangeRequests.request!`.
10. **`Guards::Execute` ships in M1b; `Commands::Execute` and the override branch ship in M3a.** The guard's
    inputs are all M1 state; the claim-then-invoke machinery is not.
11. **The gem's own suite runs on `uuid` primary keys**, since that exercises the string-cast path in §5.7.
    One migration-only CI job runs the same template with `bigint` and asserts the resulting schema.
12. **No `attempts_count` column.** `change_request_attempts` rows are the count (§5.6).
13. **No `idempotency_key` column.** The request's own id is handed to targets that declare a
    `change_request_id:` keyword, and the `executing` claim is what prevents double execution (§8).
14. **`Comment` is exempt from the undeclared-operation refusal** (§5.11), and `Cancel` requires a reason.
15. **Events carry a `System` sentinel actor**, never a NULL: `type "System"`, `id "system"`,
    `label "System"`.
16. **`kind` is a validation, not a CHECK constraint.** Later milestones add kinds; a CHECK would make each
    one a migration in every host application.

## 20. Appendix: salvage from the existing implementations

Two working implementations exist - a mountable engine and an in-app service layer. Neither is the starting
shape, and neither is ported. What follows is the list of things worth reading and lifting while writing the
gem, and nothing else.

### 20.1 Lift the code

| From                                                               | What                                                             | Use it for                                                                                         |
|--------------------------------------------------------------------|------------------------------------------------------------------|----------------------------------------------------------------------------------------------------|
| Engine `lib/change_requests/engine.rb`                             | `isolate_namespace`, generator defaults                          | §2 engine wiring                                                                                   |
| Engine `config/routes.rb`                                          | per-action opt-in routing driven by config                       | §10 `config.routes`; rewrite the top-level `included?`/`controller_name` helpers as module methods |
| Engine `lib/change_requests/*_generator.rb`                        | `Rails::Generators::Base` + `source_root` shape                  | §13 generators                                                                                     |
| Engine `spec/dummy/`                                               | dummy-app skeleton, `database.yml`, boot files                   | §15.1 dummy app                                                                                    |
| Engine `app/controllers/.../requests_controller.rb`                | `before_action` / `around_action` layout, redirect-after-command | §12 Tier 1 controller                                                                              |
| Service `app/services/change_requests/*.rb`                        | command shape: preconditions, then `request.with_lock do … end`  | §7 commands                                                                                        |
| Service `execution.rb`                                             | recording the failure *outside* the rolled-back transaction      | §8 T3                                                                                              |
| Service `change_request_approval.rb`                               | approvals as rows with a DB unique index                         | §5.4                                                                                               |
| Service `spec/support/shared_context/change_request_spec_setup.rb` | multi-actor spec fixture shape                                   | §14.1 shared contexts                                                                              |

### 20.2 Reuse the copy

The gemspec summary and description are already written and accurate to this design. The engine's
`README.md` structure (install, configure, mount, override) is a usable outline for §1 of the new README.

### 20.3 Requirements these implementations establish

Behaviours both codebases needed in production, and which this plan must therefore satisfy:

- Deferred invocation of a service by class name, method and keyword payload
- Requester may not approve their own request
- Retry of a failed execution without re-approval
- Free-text comments on a live request
- Cancellation from any non-final state
- Terminal-state immutability enforced below the command layer
- Actor and permission resolution supplied by the host, not assumed by the gem
- Per-action opt-in routing and an overridable controller

### 20.5 Non-goals inherited from the field

Nine of the ten existing approval gems approve an ActiveRecord *diff*. This gem approves a *command* - an
arbitrary declared invocation. Record-diff approval is a permanent non-goal and belongs in the first
paragraph of the README, or the issue tracker fills with requests to become a different gem.
