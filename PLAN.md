# ChangeRequests - Extraction Plan

**Date:** 2026-09-09

## Table of contents

1. [Recommendation in one page](#1-recommendation-in-one-page)
2. [Why an engine - and why not the alternatives](#2-why-an-engine--and-why-not-the-alternatives)
3. [Layering and repository layout](#3-layering-and-repository-layout)
4. [Naming: resolving the CC/ZZ collision](#4-naming-resolving-the-cockpitzazu-collision)
5. [Data model](#5-data-model)
6. [The action registry](#6-the-action-registry)
7. [Guards, commands, and the single source of truth](#7-guards-commands-and-the-single-source-of-truth)
8. [Execution safety](#8-execution-safety)
9. [Authorization and identity](#9-authorization-and-identity)
10. [Configuration surface](#10-configuration-surface)
11. [Presenters - the load-bearing layer](#11-presenters--the-load-bearing-layer)
12. [Views: the six-tier strategy](#12-views-the-six-tier-strategy)
13. [Generators and templates](#13-generators-and-templates)
14. [Test kit shipped to host apps](#14-test-kit-shipped-to-host-apps)
15. [The gem's own test suite](#15-the-gems-own-test-suite)
16. [Feature inventory](#16-feature-inventory)
17. [Porting guides](#17-porting-guides)
18. [Milestones and effort](#18-milestones-and-effort)
19. [Cut line for 1.0](#19-cut-line-for-10)
20. [Open decisions](#20-open-decisions)

## 1. Recommendation in one page

**Build one gem, packaged as a mountable Rails engine, with a hard internal seam between a headless
domain core and an optional Rails/UI layer.**

```
change_requests (one gem, one repo, one release cycle)
│
├── lib/change_requests/**          ← DOMAIN CORE.  ActiveRecord + ActiveSupport only.
│                                     Models, registry, guards, commands, presenters, errors,
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

Neither source implementation is the right starting shape on its own:

|                 | CC engine                          | ZZ service                     | This plan                                       |
|-----------------|------------------------------------|--------------------------------|-------------------------------------------------|
| Packaging       | ✅ engine, generators, config seams | ❌ in-app, nothing to require   | CC's packaging                                  |
| Concurrency     | ❌ no locking                       | ✅ `with_lock` everywhere       | ZZ's locking, plus execution outside the lock   |
| Approvals       | ❌ single `approver_id` column      | ✅ approvals table, flat quorum | ZZ's table, extended to stages                  |
| Audit trail     | ❌ mutable `varchar`                | ⚠️ jsonb array                 | New: `change_request_events` table              |
| Dispatch safety | ❌ unrestricted `constantize`       | ❌ unrestricted `constantize`   | New: action registry / allowlist                |
| Authorization   | ⚠️ caller-supplied permissions     | ❌ tautological                 | New: gem resolves permissions; pluggable policy |
| Views           | ❌ Haml, host partials, fork-to-use | ❌ Phlex, DaisyUI classes       | New: ERB + presenters + 6-tier override story   |

The plan is: **CC's packaging + ZZ's domain + four things neither has** (registry, events table,
staged approvals, execution outside the row lock).

**On views specifically:** ship ERB partials that each render a single presenter object, with a documented
locals contract, semantic prefixed CSS classes and no CSS framework - then give hosts *six* escalating ways
to customise, from a config lambda through single-partial override to a scaffold generator that writes views
into the host app in the host's own namespace. Do not make the eject-all generator the happy path; that is
exactly what turned CC's view layer into a fork button.

## 2. Why an engine - and why not the alternatives

### 2.1 Rejected: a plain service/PORO gem (the "ZZ shape")

The domain is not stateless logic; it is an aggregate with three or four tables, migrations, a lifecycle and
an authorization boundary. A gem that ships no migrations forces every adopter to hand-copy schema, and there
is no such thing as "just services" once you have `has_many :approvals`. You need at minimum a Railtie for
migration paths and generators - at which point you have an engine minus the useful parts.

### 2.2 Rejected: a concern / `acts_as_approvable` mixin

Concerns are the right shape for *record-diff* approval, where you decorate a host model and hold its
changes. This is *command* approval: the thing being approved is a serialized invocation, not a row of the
host's. There is nothing of the host's to mix into.

One narrow exception, worth shipping as an **optional** mixin:

```ruby
class Admin < ApplicationRecord
  include ChangeRequests::Actor
  # #change_requests, #change_request_approvals, #executed_change_requests,
  # #pending_change_request_approvals - scopes, not associations
end
```

Note these are **scopes over `(type, id)` string columns, not `has_many`**: there are no foreign keys to a
host table (§5.6), so an association is neither possible nor wanted. That is a convenience, not the
architecture.

### 2.3 Rejected: two gems (`change_requests` + `change_requests-rails`)

Tempting, and it is what the ZZ analysis proposed. Reject it for now:

- The core needs `activerecord` regardless, so the split does not buy "Rails-free" - it buys "actionpack-free",
  which is a small win.
- Two gems means two version numbers, a compatibility matrix, two CHANGELOGs, two release runs and twice the
  CI, carried by one maintainer. The failure mode in this niche is *maintainer attrition*, not architecture.
- The same isolation is achievable inside one gem with a directory boundary and a CI job that proves it
  (§15.5).

Revisit the split only if a real adopter appears who wants the domain without ActionView. The layout below is
designed so that split is a `git mv` and a gemspec, not a rewrite.

### 2.4 Chosen: one engine, three layers, opt-in UI

- `isolate_namespace ChangeRequests` - no constant or route leakage into the host.
- Domain code lives in **`lib/`**, not `app/models`, so it loads without `Rails::Engine`. The engine only
  contributes `app/controllers`, `app/views`, `app/helpers`, `config/routes.rb` and migration paths.
- `config.mount_ui = false` yields a pure domain + JSON gem. `true` (default when mounted) yields a working
  approvals screen.
- Migrations are **generated into the host** (`rails g change_requests:install`) rather than appended from
  the engine's `db/migrate`. CC's `append_migrations` initializer plus a config-reading migration is
  precisely how it lost reproducible schemas; generated migrations are inspectable, editable, and versioned
  in the host's repo where they belong.

## 3. Layering and repository layout

```
change_requests/
├── change_requests.gemspec
├── Gemfile
├── gemfiles/                                  # CI matrix (rails_7.1.gemfile … rails_8.1.gemfile)
├── Rakefile                                   # rake ci => rubocop + rspec + bundle:audit
├── README.md  CHANGELOG.md  LICENSE.txt  CODE_OF_CONDUCT.md
├── docs/
│   ├── 01_getting_started.md
│   ├── 02_registry.md
│   ├── 03_approval_workflows.md               # flat N-of-M and staged M-to-N
│   ├── 04_authorization.md
│   ├── 05_execution_and_idempotency.md
│   ├── 06_views_and_theming.md                # the §12 tiers, with the partial/locals contract
│   ├── 07_testing.md                          # the host test kit
│   ├── 08_events_and_notifications.md
│   ├── 09_upgrading.md
│   └── porting/{from_cockpit_engine.md,from_zazu_service.md}
│
├── lib/
│   ├── change_requests.rb                     # entrypoint: Zeitwerk loader, .configure, .registry, .request!
│   └── change_requests/
│       ├── version.rb
│       ├── configuration.rb
│       ├── errors.rb                          # the error taxonomy
│       │
│       ├── models/                            # ── LAYER 1: DOMAIN (AR + AS only) ──
│       │   ├── record.rb                      # abstract base; connection/table config
│       │   ├── request.rb
│       │   ├── stage.rb
│       │   ├── approval.rb
│       │   ├── event.rb
│       │   └── attempt.rb
│       ├── registry.rb
│       ├── registry/action.rb
│       ├── registry/workflow.rb               # stage definitions
│       ├── registry/payload_schema.rb
│       ├── guards/                            # allowed? + reason, shared by commands AND presenters
│       │   ├── base.rb approve.rb unapprove.rb reject.rb execute.rb cancel.rb comment.rb
│       ├── commands/                          # guard + mutate + emit event, inside with_lock
│       │   ├── base.rb create.rb approve.rb unapprove.rb reject.rb execute.rb cancel.rb comment.rb expire.rb
│       ├── authorization/
│       │   ├── permissions.rb                 # default: set inclusion
│       │   └── callable.rb                    # wraps any ->(actor:, request:, action:) {}
│       ├── execution/
│       │   ├── dispatcher.rb                  # registry lookup + invoke
│       │   ├── runner.rb                      # attempt bookkeeping, idempotency, retry ceiling
│       │   └── job.rb                         # ActiveJob, only defined if ActiveJob is present
│       ├── presenters/                        # ── LAYER 2: PRESENTATION-AGNOSTIC ──
│       │   ├── request_presenter.rb
│       │   ├── collection_presenter.rb
│       │   └── value/{action.rb,status.rb,stage_progress.rb,timeline_entry.rb}
│       ├── notifications.rb                   # ActiveSupport::Notifications + config hooks
│       ├── maintenance.rb                     # expire_stale!, reap_stuck_executions!
│       ├── actor.rb                           # the optional host-model concern
│       │
│       ├── engine.rb                          # ── LAYER 3: RAILS ── (required only if Rails::Engine)
│       ├── rspec.rb                           # host test kit entrypoint
│       ├── testing.rb                         # host test kit implementation
│       └── factories.rb                       # optional FactoryBot definitions
│
├── app/                                       # engine-only; never loaded headless
│   ├── controllers/change_requests/{base_controller.rb,requests_controller.rb}
│   ├── controllers/change_requests/api/requests_controller.rb
│   ├── helpers/change_requests/requests_helper.rb
│   └── views/change_requests/requests/*.html.erb
│
├── config/
│   ├── routes.rb
│   └── locales/en.yml
│
├── lib/generators/change_requests/
│   ├── install/         install_generator.rb + templates/{initializer.rb.tt,registry.rb.tt,migration.rb.tt,spec_support.rb.tt}
│   ├── action/          action_generator.rb  + templates/{action.rb.tt,action_spec.rb.tt}
│   ├── controller/      controller_generator.rb + templates/controller.rb.tt
│   ├── views/           views_generator.rb   # eject engine ERB, --only supported
│   └── scaffold_ui/     scaffold_ui_generator.rb # write host-namespaced views + controller
│
└── spec/
    ├── dummy/                                 # runnable demo app (bin/demo)
    ├── models/ registry/ guards/ commands/ execution/ presenters/
    ├── requests/                              # controller + view rendering
    ├── generators/
    ├── integration/{concurrency_spec.rb,headless_spec.rb,packaging_spec.rb}
    └── support/
```

**Dependency rule, enforced in CI:** nothing under `lib/change_requests/{models,registry,guards,commands,
authorization,execution,presenters}` may reference `ActionController`, `ActionView`, `Rails`, or any constant
under `app/`. `spec/integration/headless_spec.rb` proves it by booting the core against a bare ActiveRecord
connection with `Rails` undefined.

**Autoloading:** `Zeitwerk::Loader.for_gem` over `lib/`, with `lib/generators` and `lib/change_requests/rspec.rb`
ignored (generators are loaded by Rails' own generator lookup; the test kit is explicitly required). The
existing `zeitwerk` runtime dependency in the gemspec is correct and stays.

**Runtime dependencies:** `activerecord >= 7.1`, `activesupport >= 7.1`, `zeitwerk >= 2.6`. `railties` is
a *development* dependency plus an optional runtime one - declare it runtime only if the engine is the primary
delivery (it is), but keep every `require "rails/..."` behind `defined?(Rails::Engine)`. No `pg` runtime
dependency: PostgreSQL-only is a documented requirement, not a gem constraint on the host's adapter gem
version.

## 4. Naming: resolving the CC/ZZ collision

The two implementations use the same names for different things. Fix this once, up front, or every porting
conversation is confusing forever.

| Concept                 | CC                            | ZZ                            | **Gem**                              |
|-------------------------|-------------------------------|-------------------------------|--------------------------------------|
| The request record      | `ChangeRequests::Request`     | `ChangeRequest`               | `ChangeRequests::Request`            |
| An approval record      | *(none - a column)*           | `ChangeRequestApproval`       | `ChangeRequests::Approval`           |
| The "approve" operation | `ChangeRequests::Approval` ⚠️ | `ChangeRequests::Approval` ⚠️ | `ChangeRequests::Commands::Approve`  |
| The "execute" operation | `ChangeRequests::Execution`   | `ChangeRequests::Execution`   | `ChangeRequests::Commands::Execute`  |
| Command base            | `RequestService`              | `RequestService`              | `ChangeRequests::Commands::Base`     |
| Base error              | `ChangeRequestError`          | `ChangeRequestError`          | `ChangeRequests::Error` (+ taxonomy) |

Rule: **nouns are records, verbs are commands.** `Approval` is a row; `Approve` is a thing you do. Both prior
codebases used `Approval` for the verb, which is exactly why ZZ ended up with a `ChangeRequestApproval`
model that could not be namespaced.

Table names, fixed, no configurable prefix (a prefix option is pure maintenance tax):
`change_requests`, `change_request_stages`, `change_request_approvals`, `change_request_events`,
`change_request_attempts`.

## 5. Data model

Designed for staged M-to-N **from the first migration**. A flat 1-of-N request is simply a request with one
stage. This avoids a painful schema migration later, and costs one extra table now.

### 5.1 `change_requests`

| Column                      | Type                                     | Notes                                                          |
|-----------------------------|------------------------------------------|----------------------------------------------------------------|
| `id`                        | uuid (or bigint)                         | PK type chosen at install time                                 |
| `action_key`                | string, not null                         | registry key, e.g. `"members.update_roles"`                    |
| `service`                   | string, not null                         | resolved from the registry **at creation**, stored for audit   |
| `action`                    | string, not null                         | ditto                                                          |
| `payload`                   | jsonb, not null, default `{}`            | `attr_readonly` after create                                   |
| `title`                     | string                                   | denormalised human label, computed from the registry at create |
| `status`                    | string, not null, default `"pending"`    | **not** a PG enum - see §5.6                                   |
| `requester_type`            | string, not null                         | `"User"`, `"Admin"`, … - allowlisted, see §5.6                 |
| `requester_id`              | **string**, not null                     | string so heterogeneous PK types can share the column          |
| `requester_label`           | string, not null                         | snapshot at creation; outlives the actor record                |
| `executer_type`             | string, null                             |                                                                |
| `executer_id`               | string, null                             |                                                                |
| `executer_label`            | string, null                             | snapshot at execution                                          |
| `tenant_type`               | string, null                             | only if `config.tenant_types` is configured                    |
| `tenant_id`                 | string, null                             |                                                                |
| `tenant_label`              | string, null                             | snapshot at creation                                           |
| `payload_labels`            | jsonb, not null, default `{}`            | snapshot of human labels for the records the payload refers to |
| `workflow`                  | jsonb, not null                          | frozen snapshot of the registry's approval policy              |
| `stage_mode`                | string, not null, default `"sequential"` | `sequential` \| `parallel`                                     |
| `current_stage_position`    | integer, not null, default 1             |                                                                |
| `idempotency_key`           | string, null, **unique**                 | supplied or derived; dedupes creation                          |
| `execution_token`           | uuid, null                               | regenerated per attempt; passed to idempotent targets          |
| `attempts_count`            | integer, not null, default 0             |                                                                |
| `max_attempts`              | integer, not null, default 1             | snapshot from registry                                         |
| `expires_at`                | datetime, null                           |                                                                |
| `executed_at`               | datetime, null                           | **written** (ZZ never wrote it)                                |
| `failure_reason`            | text, null                               | plain column; the *structured* history lives in events         |
| `lock_version`              | integer, not null, default 0             | optimistic lock, belt to `with_lock`'s braces                  |
| `created_at` / `updated_at` | datetime, not null                       |                                                                |

Indexes: `(status)`, `(tenant_type, tenant_id, status, created_at DESC)`, `(requester_type, requester_id)`,
`(executer_type, executer_id)`, `(action_key)`, unique `(idempotency_key)` where not null, `(expires_at)`
where `status IN ('pending','approved')` (partial index for the expiry sweeper).

`attr_readonly :action_key, :service, :action, :payload, :payload_labels, :workflow, :requester_type,
:requester_id, :requester_label, :tenant_type, :tenant_id` - closes the "raise the quorum after approvals
exist" hole, and makes the actor snapshot genuinely immutable rather than merely conventionally so.

### 5.2 `change_request_stages`

| Column               | Type                                  | Notes                                      |
|----------------------|---------------------------------------|--------------------------------------------|
| `id`                 | uuid/bigint                           |                                            |
| `change_request_id`  | FK, not null                          |                                            |
| `position`           | integer, not null                     | unique with request_id                     |
| `name`               | string, not null                      | `"peer"`, `"owner"`                        |
| `rule`               | string, not null                      | `n_of` \| `all_of` \| `percent` \| `any`   |
| `threshold`          | integer, null                         | count for `n_of`, percentage for `percent` |
| `permission_match`   | string, not null, default `"any"`     | `any` \| `all` - **per stage**, see §5.2a  |
| `status`             | string, not null, default `"pending"` | `pending` \| `satisfied` \| `rejected`     |
| `satisfied_at`       | datetime, null                        |                                            |

Unique index `(change_request_id, position)`.

Stages are created from the frozen `workflow` snapshot when the request is created. A stage is never edited.

### 5.2a `change_request_stage_permissions` and `change_request_stage_eligible_actors`

Who may approve a stage is expressed as **rows, not as array or JSON columns**.

| `change_request_stage_permissions` | Type         | Notes                                             |
|------------------------------------|--------------|---------------------------------------------------|
| `change_request_stage_id`          | FK, not null |                                                   |
| `permission`                       | string, null | `NULL` = any permission (i.e. gate on type alone)  |
| `actor_type`                       | string, null | `NULL` = any registered actor type                 |

CHECK: `permission IS NOT NULL OR actor_type IS NOT NULL` - a row that constrains nothing is a bug, not a
wildcard.

| `change_request_stage_eligible_actors` | Type             |
|----------------------------------------|------------------|
| `change_request_stage_id`              | FK, not null     |
| `actor_type`                           | string, not null |
| `actor_id`                             | string, not null |

Unique indexes `(change_request_stage_id, permission, actor_type)` and
`(change_request_stage_id, actor_type, actor_id)`; plus reverse indexes `(permission)` and
`(actor_type, actor_id)` for the query below.

**Two nullable columns give a complete 2×2 of eligibility**, which is what lets one gem serve both an app
with several actor classes and an app with one actor class and a role list:

| `permission` | `actor_type` | Means                                       | Typical app                |
|--------------|--------------|---------------------------------------------|----------------------------|
| `"owner"`    | `NULL`       | anyone holding `owner`                      | single class + roles       |
| `"owner"`    | `"Admin"`    | Admins holding `owner`                      | several classes            |
| `NULL`       | `"Admin"`    | any Admin, whatever they hold               | several classes            |
| `NULL`       | `NULL`       | *rejected by the CHECK*                     | -                          |

So "an Admin **or** an Editor must approve, but never a User or a Creator" is two rows either way. As roles
on one class: `("admin", NULL)` and `("editor", NULL)`. As separate classes: `(NULL, "Admin")` and
`(NULL, "Editor")`, or with a permission gate as well if the class alone is too coarse.

**`permission_match` lives on the stage, not in global config.** Multiple rows on one stage mean
"any of these" under `match: :any` and "all of these" under `match: :all` - opposite meanings for identical
data, so the mode belongs next to the rows it governs rather than in an app-wide flag. `config` supplies
only the default. This lets one app hold both:

```ruby
w.stage :review, permissions: %w(admin editor),      match: :any, rule: :n_of, threshold: 1
w.stage :sign,   permissions: %w(finance compliance), match: :all, rule: :n_of, threshold: 2
```

Keep the two axes distinct: these rows decide **who may** approve; `rule` and `threshold` decide **how
many** must. "Any two of {Admin, Editor}" is one stage (`match: :any`, `threshold: 2`); "one Admin **and**
two Owners" is two stages.

Both were `text[]` / `jsonb` in an earlier draft. Rows are better on two independent grounds:

1. **The approver inbox is a real query.** "Every request awaiting *my* approval" is the badge in the
   navigation, the target list for notifications, and the first thing anyone asks a change-request system
   for. As rows it is one indexed, paginated query:

   ```sql
   -- one CTE defines "this actor satisfies this permission row", used by both match modes
   WITH matched AS (
     SELECT p.change_request_stage_id AS stage_id, p.id AS row_id
       FROM change_request_stage_permissions p
      WHERE (p.permission IS NULL OR p.permission IN (:actor_permissions))
        AND (p.actor_type  IS NULL OR p.actor_type  =  :actor_type)
   )
   SELECT r.* FROM change_requests r
     JOIN change_request_stages s
       ON s.change_request_id = r.id AND s.position = r.current_stage_position
                                     AND s.status = 'pending'
   WHERE r.status = 'pending'
     AND (
       -- eligible by permission …
       CASE s.permission_match
         WHEN 'any' THEN EXISTS (SELECT 1 FROM matched m WHERE m.stage_id = s.id)
         WHEN 'all' THEN (SELECT COUNT(*) FROM matched m WHERE m.stage_id = s.id)
                       = (SELECT COUNT(*) FROM change_request_stage_permissions p
                           WHERE p.change_request_stage_id = s.id)
       END
       -- … or by name
       OR EXISTS (SELECT 1 FROM change_request_stage_eligible_actors e
                   WHERE e.change_request_stage_id = s.id
                     AND e.actor_type = :actor_type AND e.actor_id = :actor_id)
     )
     AND NOT EXISTS (SELECT 1 FROM change_request_approvals a
                     WHERE a.change_request_stage_id = s.id
                       AND a.approver_type = :actor_type AND a.approver_id = :actor_id)
     AND (r.requester_type, r.requester_id) IS DISTINCT FROM (:actor_type, :actor_id)
   ```

   The `all` branch is a count-match rather than a plain `IN`, which is precisely why the mode has to be a
   column: the query shape differs per stage. As a `text[]` this needs `&&` and a GIN index; as `jsonb` it
   needs containment operators; in Ruby it cannot be paginated at all. Ships as
   `ChangeRequests::Request.awaiting_approval_from(actor)`, and `Guards::Approve` evaluates the identical
   predicate against a single loaded stage - one definition of eligibility, two call sites.

2. **It is the one place the schema would otherwise be PostgreSQL-shaped for no gain** - see §5.6.

Both tables are write-once, populated when the stage is materialised from the frozen workflow, and never
Both tables are write-once, populated when the stage is materialised from the frozen workflow, and never
updated - so a `permissions` list edited in the registry never changes who may approve an in-flight
request.

### 5.3 `change_request_approvals`

| Column                    | Type               | Notes                                   |
|---------------------------|--------------------|-----------------------------------------|
| `id`                      | uuid/bigint        |                                         |
| `change_request_id`       | FK, not null       | denormalised for cheap counting/scoping |
| `change_request_stage_id` | FK, not null       |                                         |
| `approver_type`           | string, not null   | allowlisted, see §5.6                   |
| `approver_id`             | string, not null   |                                         |
| `approver_label`          | string, not null   | snapshot at decision time               |
| `decision`                | string, not null   | `approved` \| `rejected`                |
| `comment`                 | text, null         |                                         |
| `decided_at`              | datetime, not null |                                         |
| `created_at`/`updated_at` | datetime, not null | ZZ omitted these; keep them             |

**Unique index `(change_request_stage_id, approver_type, approver_id)`** - the DB, not application code,
enforces one-decision-per-approver-per-stage. (ZZ's index was per request; per stage is correct once stages
exist. The type must be part of the key: a `User#7` and an `Admin#7` are two different people.)

### 5.4 `change_request_events` - the audit trail

Append-only. Replaces CC's mutable `comment` varchar and ZZ's `comments` jsonb array, and kills the
symbol/string-key class of bug outright.

| Column              | Type                          | Notes                                                      |
|---------------------|-------------------------------|------------------------------------------------------------|
| `id`                | uuid/bigint                   |                                                            |
| `change_request_id` | FK, not null                  |                                                            |
| `actor_type`        | string, null                  | null for system events (expiry, reaper)                    |
| `actor_id`          | string, null                  |                                                            |
| `actor_label`       | string, null                  | snapshot; `"System"` for gem-originated events             |
| `kind`              | string, not null              | see below                                                  |
| `body`              | text, null                    | free text: comment body, rejection reason, failure message |
| `metadata`          | jsonb, not null, default `{}` | stage name, attempt number, previous status, …             |
| `occurred_at`       | datetime, not null            |                                                            |

Kinds: `requested`, `approved`, `unapproved`, `rejected`, `commented`, `canceled`, `stage_satisfied`,
`execution_started`, `executed`, `execution_failed`, `expired`, `reaped`.

Index `(change_request_id, occurred_at)`. No `updated_at` - rows are immutable; enforce with
`before_update { raise ActiveRecord::ReadOnlyRecord }` and, optionally, a documented PG rule/trigger snippet
for hosts that want it enforced below the application.

**Commenting on completed requests is allowed** (ZZ forbade it). Post-mortem notes on a `successful` or
`canceled` request are the whole point of an audit trail. Terminal-state protection applies to the request
row's lifecycle columns, not to appending events.

### 5.5 `change_request_attempts`

| Column                                                                                                                                          | Type | Notes                                |
|-------------------------------------------------------------------------------------------------------------------------------------------------|------|--------------------------------------|
| `id`, `change_request_id` FK, `number` int, `execution_token` uuid                                                                              |      | unique `(change_request_id, number)` |
| `executer_type`/`executer_id`/`executer_label`, `started_at`, `finished_at`, `outcome` (`succeeded`\|`failed`\|`abandoned`), `error_class`, `error_message`, `backtrace` text |      |                                      |

This is what makes "did the outbound call happen before it blew up?" answerable, and what makes a retry
ceiling enforceable.

### 5.6 Four deliberate schema choices

**No PostgreSQL enums.** CC's `permission` enum read the initializer at migration time, so replaying
migrations on a fresh database produced a different schema than production, and every new permission needed a
hand-written `ALTER TYPE … ADD VALUE` with `disable_ddl_transaction!`. Use `string` + an inclusion validation
+ a CHECK constraint written into the generated migration. PostgreSQL-only is about `jsonb`,
partial indexes and `FOR UPDATE` - none of which the enum buys.

**No foreign keys to host tables. Polymorphic actor references, chosen per request, with snapshotted
labels.**

Both sources got this wrong, in opposite directions. CC stored bare UUIDs with no type and no associations:
decoupled, but the UI could only ever render a raw ID, and nothing said *which* table the ID belonged to.
ZZ stored a real `belongs_to` + FK to a single `Member` class: one actor class was baked into the schema,
and deleting a member either hit the constraint or took the audit trail with it.

Two requirements rule both out:

- **Several actor classes coexist in one app** - `User`, `Admin`, `Manager` - and which one applies is
  decided **when the change request is created**, never at install time.
- **A deleted actor must not break a historical view.** The same holds for records the payload refers to.
  An audit trail that stops rendering because someone was offboarded is not an audit trail.

So every reference to a host record is a **triple**:

| Concern           | Column     | Notes                                                     |
|-------------------|------------|-----------------------------------------------------------|
| Which class       | `*_type`   | string, validated against the configured allowlist (§9)   |
| Which record      | `*_id`     | **string**                                                |
| What to display   | `*_label`  | captured at write time, `attr_readonly`, never recomputed |

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
   hosts that want strict point-in-time audit semantics (§20.7).

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

- **No array columns.** `stage.permissions` and named approvers are join tables (§5.2a) - which is the
  better design anyway, since it is what makes the approver inbox a paginatable query.
- **`jsonb` for storage, never for correctness.** `payload`, `payload_labels`, `workflow` and event
  `metadata` are written and read whole, in Ruby. No `@>`, no `->>`, no GIN index is load-bearing. A jsonb
  operator may be used as an *optimisation* behind a method, never as the only implementation of a
  behaviour.
- **Partial indexes are optimisations, not semantics.** Correctness never depends on one. The unique
  `idempotency_key` is the only case where it is close, and the plain unique index is the fallback.

Everything else stays unapologetically PostgreSQL: `jsonb` (not `json`), partial indexes, `FOR UPDATE`.
Note that §8's atomic claim is a conditional `UPDATE … WHERE status = …` with a zero-rows check rather than
a `FOR UPDATE` read - chosen for correctness, portable as a side effect.

**Payload records get the same treatment.** A registry action may declare how to label the records its
payload references, and the result is snapshotted at creation:

```ruby
a.payload_labels = ->(payload) { { member_id: Member.find_by(id: payload[:member_id])&.name } }
```

`title` and `payload_labels` together mean the show page for an old request stays fully readable after both
the actor and the target record are gone. This is the reason `title` is denormalised rather than recomputed,
and it is worth spelling out in the README - it is a genuine differentiator over every record-diff gem in
the field, all of which render nothing once the record is destroyed.

### 5.7 Lifecycle

```
                    ┌───────────── unapprove (quorum lost) ─────────────┐
                    ▼                                                   │
  (create) ──▶ pending ──── approve × N per stage ─────▶ approved ──────┘
                 │ │                                        │
                 │ │                                        ├── execute ──▶ executing ──▶ successful ▲ final
                 │ │                                        │                    │
                 │ │                                        │                    └──▶ failed ──┐
                 │ │                                        │                          ▲       │ retry
                 │ └──── reject ──▶ rejected ▲ final        │                          └───────┘
                 │                                          │                          (max_attempts)
                 ├──── cancel ──▶ canceled ▲ final ◀────────┤
                 └──── expire ──▶ expired  ▲ final ◀────────┘
```

`STATUSES = %w(pending approved executing successful failed rejected canceled expired)`
`FINAL_STATUSES = %w(successful rejected canceled expired)`

Two additions over both sources: **`executing`** (§8) and **`rejected`** (an explicit "no", with a reason,
distinct from "never mind" - non-negotiable for a public approval gem).

Terminal-state protection stays at the model layer, as in both sources - `before_update` raising if
`status_was` was final. It is the right defensive choice: it holds even when a caller bypasses the commands.

## 6. The action registry

The single highest-value new component. It is the allowlist that closes `constantize` + `public_send` on
arbitrary stored strings, and it is simultaneously the payload schema, the approval policy, and the retry
policy. One object solves five problems.

```ruby
# config/initializers/change_requests_registry.rb  (generated by the install generator)

ChangeRequests.registry.draw do
  action "members.update_roles" do |a|
    a.service = "Members::UpdateRoles"
    a.action  = :call                             # must be a public singleton method
    a.title   = ->(payload) { "Update roles for member #{payload[:member_id]}" }

    a.payload_schema do |s|
      s.uuid   :member_id, required: true
      s.array  :roles, of: :string, required: true, in: %w(owner admin editor viewer)
    end

    a.idempotent   = true                          # may be retried safely
    a.max_attempts = 3
    a.expires_in   = 7.days

    # flat N-of-M shorthand:
    a.approvals permissions: %w(member_admin), required: 2

    # …or a staged M-to-N workflow:
    a.workflow mode: :sequential do |w|
      # "an admin OR an editor" - roles on a single actor class
      w.stage :review, permissions: %w(admin editor), match: :any, rule: :n_of, threshold: 1

      # "any Admin, or a User holding :owner" - several actor classes, mixed gating
      w.stage :owner,  permissions: [{ actor_type: "Admin" },
                                     { permission: "owner", actor_type: "User" }],
                       match: :any, rule: :n_of, threshold: 2

      # "must hold BOTH finance and compliance", plus two named approvers by hand
      w.stage :sign,   permissions: %w(finance compliance), match: :all,
                       eligible_actors: [cfo, general_counsel], rule: :all_of
    end
  end
end
```

**Guarantees the registry provides**

1. **Dispatch allowlist.** `Execution::Dispatcher` resolves `action_key → (service, action)` from the
   registry, never from the stored strings. The stored `service`/`action` columns become audit data, not
   dispatch input. A row whose `action_key` is no longer registered is unexecutable, by construction. This
   is the RCE fix, and it survives careless `create` endpoints.
2. **Payload validation at creation.** A typed schema validated when the request is made, not discovered as
   an `ArgumentError` at execution time, weeks later, by the person clicking Execute.
3. **Approval policy is policy, not caller input.** `required_approvals` / `permissions` come from the
   registry; the caller cannot supply them.
4. **Snapshot-on-create.** The resolved workflow is frozen into `change_requests.workflow` and materialised
   into `change_request_stages`. Editing the registry never retroactively changes in-flight requests, and
   never leaves a request wrongly `approved` or wrongly `pending`.
5. **Explicit retryability.** `idempotent` and `max_attempts` are per-action declarations, not an implicit
   global "failed requests can be retried forever".
6. **Boot-time verification.** `ChangeRequests.registry.verify!` (called from `to_prepare` in dev/test, and
   available as `rake change_requests:verify`) asserts every service constant resolves, every action exists
   as a public singleton method, every declared permission is a String, and every schema key corresponds to a
   keyword parameter of the target method. This is the fix for CC's validator/executor mismatch, where
   validation checked `instance_methods` and execution called a class method - a first-five-minutes failure
   for any adopter using the ordinary `def self.call` idiom.

**Creation API:**

```ruby
request = ChangeRequests.request!(
  "members.update_roles",
  payload:   { member_id: member.id, roles: %w(editor) },
  requester: current_user,
  tenant:    current_organization,     # optional
  idempotency_key: "roles:#{member.id}:#{digest}"   # optional; dedupes
)
```

Raises `ChangeRequests::UnknownAction`, `ChangeRequests::InvalidPayload`, or `ChangeRequests::NotAuthorized`.

**The service contract, documented explicitly** (neither source documented it, and both broke on it):

> A change-request target is a **public singleton method** that accepts **keyword arguments only** and whose
> effect is either transactional or idempotent. It receives `execution_token:` if it declares that keyword,
> so external calls can carry an idempotency key.

## 7. Guards, commands, and the single source of truth

ZZ's most instructive bug: `ChangeRequest#approvable_by?` (used by the UI) and
`ChangeRequests::Approval` (the enforcement) checked *different* conditions, so the button and the service
drifted by construction, and the missing check surfaced as a `RecordNotUnique` 500.

Fix structurally: **one guard object, consulted by both the command and the presenter.**

```ruby
module ChangeRequests
  module Guards
    class Approve < Base
      def allowed?  = reason.nil?
      def reason                      # nil when allowed, an i18n-able symbol/message otherwise
        return :not_pending      unless request.pending?
        return :requester        if request.requester_id == actor.id && !config.requester_may_approve
        return :already_decided  if current_stage.approvals.exists?(approver_id: actor.id)
        return :not_permitted    unless authorization.allows?(actor:, request:, stage: current_stage, action: :approve)
        nil
      end
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
        request.with_lock do                       # SELECT … FOR UPDATE, as ZZ does
          Guards::Approve.new(request:, actor:).check!
          approval = current_stage.approvals.create!(approver_id: actor.id, decision: "approved", comment:)
          emit(:approved, metadata: { stage: current_stage.name })
          advance_workflow!                        # satisfy stage, advance position, maybe → approved
          request
        end
      end
    end
  end
end
```

Commands: `Create`, `Approve`, `Unapprove`, `Reject`, `Execute`, `Cancel`, `Comment`, `Expire`.

Signature change from both sources, and it matters:

```ruby
# ZZ / CC - caller supplies permissions.  This is how the tautology got in.
Approval.call(request_id:, actor_id:, permissions:)

# Gem - caller supplies only the actor.  The gem resolves permissions itself.
ChangeRequests::Commands::Approve.call(request:, actor:, comment: nil)
```

**Never accept permissions from the caller.** A controller that passes `@request.permissions` produces a
guard that evaluates `(x - x).blank?` - always true - and no test that stubs the actor's roles will ever
catch it. Removing the parameter removes the bug class.

**Error taxonomy** (`lib/change_requests/errors.rb`) - hosts need to rescue precisely, and half of ZZ's
error paths returned HTTP 500 because only one class was rescued:

```
ChangeRequests::Error
├── ConfigurationError            (no actor types registered, invalid registry)
├── UnknownActorType              (an actor whose class is not registered)
├── UnknownAction
├── InvalidPayload                (=> details hash)
├── NotAuthorized
├── TransitionError
│   ├── NotApprovable  ├── NotUnapprovable  ├── NotRejectable
│   ├── NotExecutable  ├── NotCancelable    ├── AlreadyFinalized
│   └── QuorumNotMet
├── ExecutionError
│   ├── TargetFailed              (wraps the original; #cause preserved)
│   ├── AttemptsExhausted
│   └── ExecutionInProgress
└── StaleRequest                  (optimistic lock conflict)
```

Every `TransitionError` carries `#request`, `#reason` (a symbol) and a translated `#message`. The engine
controller `rescue_from ChangeRequests::Error` once, and hosts get a flash instead of an exception page.

## 8. Execution safety

CC had **no locking at all** - two concurrent `POST /execute` both passed `executable?` and both invoked
the service. ZZ locked correctly but held `SELECT … FOR UPDATE` across the target invocation, including
outbound HTTP.

Both problems are solved by splitting execution into three transactions:

```
T1  with_lock:  Guards::Execute.check!
                status pending→executing (conditional UPDATE … WHERE status IN ('approved','failed'))
                attempts_count += 1; create Attempt(number:, execution_token: SecureRandom.uuid)
                emit(:execution_started)
                COMMIT  ← the claim is now visible to every other process

T2  no lock:    Dispatcher.call(action_key:, payload:, execution_token:)
                ← may take seconds, may call an external API, holds no row lock

T3  with_lock:  success → executed_at, executer_id, status=successful, attempt.outcome=succeeded, emit(:executed)
                failure → status=failed, failure_reason, attempt.outcome=failed + error class/message,
                          emit(:execution_failed)
```

Zero rows updated by T1's conditional UPDATE means another process claimed it - raise
`ExecutionInProgress`, do not invoke. This is the double-execution fix, and it is stronger than
`with_lock` alone because the claim is *committed* before the side effect runs.

Note the deliberate detail ZZ got right and worth preserving: **the failure is recorded outside the
rolled-back transaction**, so a target that raises leaves no business change but does leave a durable record
of the failure.

Additional guarantees:

- **Retry ceiling.** `retryable?` is `failed? && registry_action.idempotent? && attempts_count < max_attempts`.
  CC and ZZ both allowed unbounded retries of a non-idempotent side effect.
- **Idempotency token.** Each attempt carries an `execution_token`; targets that declare an
  `execution_token:` keyword receive it and can dedupe against a payment provider or webhook endpoint.
  Retries of the *same* attempt reuse the token; a new attempt gets a new one.
- **Stuck-execution reaper.** `ChangeRequests::Maintenance.reap_stuck_executions!(older_than: 1.hour)`
  moves `executing` rows whose attempt never finished to `failed` with `outcome: abandoned` and a `reaped`
  event. Ship it as a rake task and document scheduling it.
- **Background mode.** `config.execution_mode = :background` makes T2/T3 run in
  `ChangeRequests::Execution::Job`. T1 still commits synchronously, so the UI immediately shows `executing`.
  The job class is only defined when ActiveJob is loaded - no hard dependency.
- **Expiry.** `Maintenance.expire_stale!` moves `pending`/`approved` requests past `expires_at` to `expired`.

**Separation of duties** becomes explicit configuration rather than an accident:

```ruby
config.requester_may_approve = false   # hard-wired false; setting true raises ConfigurationError
config.requester_may_execute = false   # ZZ's spec asserted true; defensible, but must be a choice
config.approver_may_execute  = true
```

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

   The registration list is simultaneously: the `*_type` allowlist (§5.6 consequence 5), the label source,
   the permission source, the batch resolver used by `CollectionPresenter`, and the per-type key cast. STI
   subclasses register once under their `base_class`.

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
   `permissions` lambda and checks it against the stage's permission rows (§5.2a) - so `User` and `Admin` can
   derive their permissions completely differently and still be compared against one stage definition.
Both matching semantics ship, but as a **per-stage** setting rather than an app-wide one, because
   identical rows mean opposite things under each (§5.2a). ZZ's AND-of-all-roles is a narrow default;
   `config.default_permission_match = :any` supplies the default and every stage may override it.

   Because `permission` and `actor_type` are independently nullable, one mechanism covers both shapes of
   app: several actor classes (`Admin`, `Editor`, `Manager`), a single class carrying roles, or a mix of
   the two in one workflow - see the 2×2 in §5.2a.

   Named approvers (`change_request_stage_eligible_actors` rows) are OR-ed with the permission check when
   present - and because both are rows, the same predicate serves the guard *and* the inbox query in §5.2a,
   so "the button is enabled" and "it appears in my inbox" cannot drift apart.

3. **Which requests can this actor see?** `config.visible_scope = ->(scope, actor) { … }`, defaulting to
   tenant scoping when `config.tenant_types` is configured, and to `scope` otherwise. Note the scope is
   written against `tenant_type` + `tenant_id` string columns, not an FK. The engine controller applies
   it to **both** `index` and `show` - ZZ's `show` was an IDOR on any UUID because tenant scoping was
   applied to neither. Ship a request spec that asserts a cross-tenant `show` 404s; that is the test that
   would have caught it.

Pundit and ActionPolicy get **documented recipes in `docs/04_authorization.md`, not gem dependencies.**

## 10. Configuration surface

`ChangeRequests.config` always returns a memoised instance (never `nil` - CC's `configure`-replaces-
the-object design surfaced misconfiguration as `NoMethodError on nil`). `configure` mutates in place, and
`validate!` runs in `after_initialize` with actionable messages.

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

  config.actor_label_strategy = :live          # :live (default) | :snapshot - see §20.7
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
  config.default_permission_match = :any        # per-stage override in the registry

  # ── separation of duties ─────────────────────────────────────────────────
  config.requester_may_execute = false
  config.approver_may_execute  = true

  # ── execution ────────────────────────────────────────────────────────────
  config.execution_mode        = :inline        # :inline | :background
  config.job_class             = "ChangeRequests::Execution::Job"
  config.job_queue             = :default
  config.default_max_attempts  = 1
  config.default_expires_in    = nil

  # ── events & notifications ───────────────────────────────────────────────
  config.on_event              = ->(event) { ChangeRequestMailer.notify(event).deliver_later }
  config.instrument            = true           # ActiveSupport::Notifications "*.change_requests"

  # ── UI (ignored when the engine is not mounted) ──────────────────────────
  config.mount_ui              = true
  config.parent_controller     = "ApplicationController"
  config.layout                = "application"
  config.routes                = %i(index show approve unapprove reject execute cancel comment)
  config.per_page              = 25
  config.stylesheet            = true           # ship the optional CSS
  config.datetime_format       = :short         # I18n.l format key
  config.payload_renderer      = nil            # ->(request, view) { … }
  config.helper_module         = nil            # "MyChangeRequestsHelper"
end
```

Every UI key is inert when `mount_ui` is false, so a headless adopter never has to think about them.

## 11. Presenters - the load-bearing layer

**Do this even if the gem never ships.** It is the piece that makes the UI testable without rendering, gives
a JSON API for free, fixes the model/service/UI drift, and makes every renderer below it a thin adapter.

```ruby
p = ChangeRequests::RequestPresenter.new(request, actor:, routes: view)

p.title                # "Update roles for member 8f2c…"
p.action_key           # "members.update_roles"
p.requester            # ActorRef - #label, #deleted?, #path; never a raw UUID
p.executer             # ActorRef or nil
p.status               # Value::Status(key: :failed, label: "Failed", tone: :danger,
                       #               tooltip: "Timeout calling provider")
p.stages               # [ Value::StageProgress(name: "peer",  label:, required: 1, approved: 1,
                       #                        satisfied?: true,  approvers: ["Ada"], current?: false),
                       #   Value::StageProgress(name: "owner", label:, required: 2, approved: 0,
                       #                        satisfied?: false, approvers: [],      current?: true) ]
p.actions              # [ Value::Action(name: :approve, label: "Approve", enabled: true,
                       #                 reason: nil, method: :post, path: "/change_requests/…/approve",
                       #                 confirm: nil, tone: :primary),
                       #   Value::Action(name: :execute, label: "Execute", enabled: false,
                       #                 reason: "Needs 2 more approvals from Owner", …) ]
p.timeline             # ordered Value::TimelineEntry - one per event row, actor-labelled, i18n'd
p.payload_rows         # [[label, formatted_value], …]  - honours config.payload_renderer
p.as_json              # the full contract, stable and versioned
```

Key properties:

- **`actions` is computed from the same `Guards::*` objects the commands enforce with.** A disabled button
  and a raised `NotApprovable` can never disagree, and the `reason` shown in the tooltip is the same reason
  the command would have raised.
- **`CollectionPresenter` owns eager loading**, so the N+1 is fixed once. It preloads
  `stages: :approvals` and `events`, then collects every `ActorRef` on the page, **groups them by
  `actor_type`, and issues one query per type** through that type's registered `finder` - three actor
  classes on a page of 25 requests costs three queries, not seventy-five. Never `find_by` per row (ZZ
  wasted its preload by calling `approvals.find_by(...)` inside a component).
- **Actor resolution is optional, not required.** Every label is already on the row, so a presenter
  constructed with `resolve_actors: false` renders a complete page with **zero** queries against host
  tables. That is the fast path for large index pages, and the only path once an actor class has been
  removed from the app entirely.
- **Deleted actors degrade, never raise.** `ActorRef#label` falls back to the snapshot and `#deleted?`
  becomes true, so `_actor.html.erb` renders "Ada Lovelace (deleted)" with no link. A view spec asserts
  exactly this against a request whose actor row has been hard-deleted.
- **No ActionView dependency.** `routes:` is an optional injected url-helper object; when absent, `path` is
  nil and `as_json` still works. This keeps presenters in the domain core, usable from a JSON API or a
  background job.
- **`as_json` is the documented public contract**, versioned in `docs/06_views_and_theming.md`. Any
  alternative front end - Hotwire, React, Phlex, Avo - targets it.

## 12. Views: the six-tier strategy

The specific question: *how to offer views, and how to support hosts creating their own.*

The evidence from CC is decisive. Its `change_requests:views` generator copied all nine partials into
the host - and comparing engine to host afterwards showed exactly **three** real customisations: render an
actor instead of a raw ID, format a timestamp, and render the payload. Three lambdas' worth of difference
caused a permanent fork of nine files, through which no upstream fix can ever travel.

So: **make the three common customisations require zero files, and make eject the last resort, not the
first step.**

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
  with a server-rendered fallback. ZZ's `Datetime` component already had the right pattern - server-side
  `I18n.l` with client enhancement - keep it.
- No Tailwind, no DaisyUI, no Bootstrap class names. ZZ hardcoded `class: "primary small"`; that is what
  binds a gem to one host's design system.

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

**Three configuration seams** - chosen because they are empirically the three things CC's host had to fork
for: rendering an actor, formatting a timestamp, rendering the payload.

```ruby
config.actor_type "User" { |t| t.label = ->(u) { u.display_name }
                                t.path  = ->(u, routes) { routes.admin_user_path(u) } }
config.datetime_format   = :long             # or ->(time) { time_ago_in_words(time) }
config.payload_renderer  = ->(request, view) { view.render "admin/payload", request: }
```

Actor rendering is per type rather than one global lambda, which is what lets a `User` and an `Admin` render
differently - a distinction neither source implementation could express at all.

**All strings through I18n**, defaults in `config/locales/en.yml`, every key namespaced under
`change_requests.*`. Statuses, action labels, guard reasons, confirmations, empty states.

### Tier 3 - Override one partial

Rails searches the host's view paths before the engine's. A file at
`app/views/change_requests/requests/_row.html.erb` in the host replaces exactly that partial. Nothing else is
forked; every other partial keeps receiving upstream fixes.

This only works if the partial inventory and its locals are a **documented, semver-covered contract**. That
document is the single most valuable piece of view support in the plan:

| Partial                    | Locals                                  | Purpose                                     |
|----------------------------|-----------------------------------------|---------------------------------------------|
| `index.html.erb`           | `collection:` (CollectionPresenter)     | page shell                                  |
| `_filters.html.erb`        | `filters:`, `url:`                      | status / action_key / requester filters     |
| `_table.html.erb`          | `collection:`                           | `<thead>` + one `<tr>` per row              |
| `_row.html.erb`            | `request:` (RequestPresenter)           | one request                                 |
| `_status.html.erb`         | `status:` (Value::Status)               | the pill                                    |
| `_stage_progress.html.erb` | `stages:` (Array<Value::StageProgress>) | "1/1 peer · 0/2 owner"                      |
| `_actions.html.erb`        | `actions:` (Array<Value::Action>)       | the button group                            |
| `_action_button.html.erb`  | `action:`                               | one button, enabled or disabled-with-reason |
| `show.html.erb`            | `request:`                              | detail page shell                           |
| `_payload.html.erb`        | `request:`                              | payload table                               |
| `_timeline.html.erb`       | `entries:`                              | the audit trail                             |
| `_timeline_entry.html.erb` | `entry:`                                | one event                                   |
| `_comment_form.html.erb`   | `request:`, `url:`                      | add a comment                               |
| `_actor.html.erb`          | `actor:` (ActorRef, or nil)             | actor seam; handles deleted and system actors |
| `_datetime.html.erb`       | `time:`, `format:`                      | timestamp seam                              |
| `_empty.html.erb`          | -                                       | empty state                                 |

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
longer receive upstream changes, and a pointer back to Tier 2/3. CC's generator was documented as the
happy path; that framing is the mistake.

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

`RequestPresenter#as_json` plus `ChangeRequests::Api::RequestsController` (opt-in via
`config.routes` including `:api`) give a JSON surface for Hotwire, React, or a mobile client.
`docs/06_views_and_theming.md` documents the JSON schema and shows a ~60-line Phlex component set written
against the presenter, as a worked example - demonstrating that alternative renderers are cheap *because* the
logic is in the presenter, without shipping a Phlex dependency.

**Explicitly deferred:** `change_requests-phlex` and `change_requests-view_component` satellite gems. Revisit
post-1.0 if demand appears. One maintainer, one renderer.

### Verifying custom views

Ship shared examples so ejected and hand-written views stay honest (§14):

```ruby
it_behaves_like "a change requests index view", path: admin_change_requests_path
it_behaves_like "a change requests row partial", partial: "admin/change_requests/row"
```

These assert the class contract, that disabled actions render their reason, that no raw UUID leaks where an
actor label belongs, and that every action button is a real form. A host that ejects views gets a regression
suite for free.

## 13. Generators and templates

| Generator                                   | Produces                                                                                     |
|---------------------------------------------|----------------------------------------------------------------------------------------------|
| `change_requests:install`                   | initializer, registry initializer, migrations, optional spec-support file, README next-steps |
| `change_requests:action NAME`               | a registry entry stub + a target service stub + its spec                                     |
| `change_requests:controller`                | a subclass of `ChangeRequests::RequestsController` for host overrides                        |
| `change_requests:views [--only] [--list]`   | ejects ERB partials                                                                          |
| `change_requests:scaffold_ui [--namespace]` | host-namespaced controller + views                                                           |
| `change_requests:migration_upgrade`         | schema migrations between gem majors                                                         |

Install generator options:
`--primary-key-type=uuid --actor-types=User,Admin --tenant-types=Organization --skip-tenant
 --with-specs --mount-at=/change_requests`

`--primary-key-type` governs the gem's **own** primary keys only. The generator asks nothing about the
host's actor tables and writes no reference to them: `--actor-types` merely pre-fills the initializer's
`config.actor_type` blocks as commented stubs, and passing nothing is fine - the schema is identical either
way. Adding a fourth actor class later is an initializer edit, never a migration.

Templates shipped (`lib/generators/change_requests/*/templates/`):

- `initializer.rb.tt` - every config key, commented, with the chosen actor/tenant filled in
- `registry.rb.tt` - one worked example action, commented
- `create_change_requests.rb.tt` - all five tables, FKs **between the gem's own tables only**, CHECK
  constraints, composite `(type, id)` indexes on every actor reference, partial indexes; correct PK type
- `controller.rb.tt` - subclass stub showing how to override `find_requests`, `actor`, `after_command`
- `spec_support.rb.tt` - `require "change_requests/rspec"` + config for the host suite (§14)
- `en.yml.tt` - a copy of the gem's locale file for hosts that want to edit rather than override
- `_*.html.erb` - the ERB partial set (for the views generator)
- `action.rb.tt` / `action_spec.rb.tt` - a service stub with the correct singleton-keyword-argument shape,
  and a spec that already includes `it_behaves_like "a registered change request action"`

**Packaging note, learned from CC:** its `spec.files` glob omitted `templates/`, so both generators
resolved `source_root` to a directory that did not exist in the packaged gem - they worked only because it
was a `path:` dependency. `spec/integration/packaging_spec.rb` (§15.4) makes that failure impossible to ship
again.

## 14. Test kit shipped to host apps

Adopters must be able to test *their* actions and *their* views. Ship a first-class test kit - this is a
genuine differentiator, and it is cheap once presenters and guards exist.

```ruby
# spec/rails_helper.rb (or the file the install generator writes)
require "change_requests/rspec"
```

### 14.1 Shared contexts

```ruby
include_context "with change requests"            # config isolation, registry sandbox, cleanup
include_context "with an approved change request" # fast-forwards a request past its whole workflow
```

### 14.2 Registry sandboxing

```ruby
ChangeRequests::Testing.registry_sandbox do |registry|
  registry.action("test.noop") { |a| a.service = "TestTarget"; a.action = :call
                                     a.approvals permissions: %w(admin), required: 1 }
  # …
end                                                # original registry restored afterwards
```

Prevents host specs from mutating the real registry, and lets domain specs run without the host's actions.

### 14.3 Builders (no FactoryBot required)

```ruby
ChangeRequests::Testing.build_request(action_key: "test.noop", requester: user, payload: {})
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
expect(ChangeRequests.config).to have_registered_actor_type("Admin")
expect { command }.to emit_change_request_event(:executed).with_actor(carol)
expect { command }.to change_request_status_from(:approved).to(:successful)
expect(presenter.actions).to include_enabled_action(:approve)
expect(ChangeRequests.registry).to have_registered_action("members.update_roles")
```

### 14.5 Shared examples - the highest-value item

```ruby
# In the host app, once per registered action. Proves the registry is sound before production does.
RSpec.describe "members.update_roles" do
  it_behaves_like "a registered change request action", "members.update_roles"
end
```

That shared example asserts: the service constant resolves; the action is a public singleton method; every
`payload_schema` key is an accepted keyword argument of that method; declared permissions are Strings that
at least one registered actor type's `permissions` lambda can actually produce; `idempotent`/`max_attempts` are coherent (a
non-idempotent action may not declare `max_attempts > 1`); and, if the action declares
`execution_token:`, that the method accepts it.

Also shipped:

- `"a guarded change request command"` - for hosts writing custom commands
- `"a change requests index view"`, `"a change requests row partial"` - the view contract (§12)
- `"an idempotent change request target"` - runs the target twice with the same `execution_token` and
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
ChangeRequests::Testing.freeze_registry!     # raise on any registry mutation (CI safety)
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
  non-idempotent, honours `execution_token:`), `Demo::Explode` (always raises)
- Seeds covering every status and a two-stage workflow

`bin/demo` boots it on `localhost:3000` with seeds. This is the view-development harness and the source of
the README screenshots. It costs nothing extra and pays for itself the first afternoon spent on CSS.

### 15.2 Coverage targets

Both source implementations tested only the command objects. Everything else - controllers, routes,
generators, views, configuration, and the model validations - was untested, and every critical bug lived in
that untested territory. Required areas:

- models (validations, terminal-state guard, readonly attributes, event immutability)
- registry (verification, payload schema, snapshotting, unknown-action rejection)
- guards (a truth table per guard × status × actor role - table-driven, one `where` per row)
- commands (happy path, every guard rejection, event emission, workflow advancement)
- workflow (sequential and parallel stages; `n_of`, `all_of`, `percent`, `any`; unapproval demoting a
  satisfied stage; rejection short-circuiting a sequential workflow)
- eligibility (the full 2×2 of nullable `permission` × `actor_type`, under both `match` modes, across all
  three dummy actor classes; the CHECK rejecting a doubly-NULL row; named approvers OR-ed in) - and a spec
  asserting `Guards::Approve` and `Request.awaiting_approval_from` agree on every cell, since that
  agreement is the whole reason eligibility is rows
- execution (success, target raises, retry ceiling, non-idempotent refusal, token propagation, reaper)
- presenters (actions match guards for every status × actor combination; `as_json` schema snapshot)
- controllers/routes (opt-in route list, tenant scoping on **index and show**, error taxonomy → flash,
  Turbo and non-Turbo responses)
- views (rendering, class contract, disabled-reason rendering, no raw UUIDs)
- generators (`Rails::Generators::TestCase` for all six; assert generated migrations actually run)
- configuration (`validate!` messages; defaults; `config` never nil)

### 15.3 Concurrency specs

Real threads, real connections, real PostgreSQL - this is the class of bug that killed CC:

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

### 15.5 Headless spec - proves the layering

```ruby
# Run in a subprocess with Rails never required.
it "loads and operates the domain core without Rails" do
  out = `ruby -Ilib spec/integration/headless_script.rb`   # AR connection, migrate, create, approve, execute
  expect(out).to include("successful")
end
```

Plus a static check that no file under the domain directories mentions `ActionController|ActionView|Rails\.`.

### 15.6 CI matrix

- Ruby: per §20 decision - proposed `3.2`, `3.3`, `3.4`, `4.0`
- Rails: `7.1`, `7.2`, `8.0`, `8.1` via `gemfiles/*.gemfile` + `BUNDLE_GEMFILE`
- PostgreSQL: `14` and `17` service containers
- Jobs: `rubocop`, `rspec` (matrix), `bundle:audit`, `headless`, `packaging`, `generators-on-a-real-app`
  (generate a throwaway Rails app, run `change_requests:install`, run the migrations, boot it - the test
  that catches everything the dummy app's `path:` dependency hides)

## 16. Feature inventory

### Ported from one or both sources

- Deferred, persisted, replayable service invocation (both)
- Separation of duties between requester and approver (both)
- Full lifecycle: approve, unapprove, execute, retry, cancel, comment (both)
- Terminal-state protection at the model layer (both)
- Failure capture with retry of failed executions (both)
- Host-agnostic actor resolution; opt-in routes; overridable controller (CC)
- Mountable engine, generators, migration handling (CC)
- Approvals as rows with a DB unique constraint (ZZ)
- Flat N-of-M quorum with automatic demotion when a quorum is lost (ZZ)
- Pessimistic locking on every mutation (ZZ)
- Failure recorded outside the rolled-back transaction (ZZ)
- Creation-time validation that the target exists (both, correctly this time)

### New - required for 1.0

| Feature                                                                                | Replaces / solves                                                                                            |
|----------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| **Action registry** (allowlist + schema + policy + retry declaration)                  | unrestricted `constantize`; caller-supplied quorum; unvalidated payloads; the class/instance method mismatch |
| **Staged M-to-N workflows** (`sequential`/`parallel`, `n_of`/`all_of`/`percent`/`any`) | flat quorum in ZZ, 1-of-N in CC                                                                              |
| **`change_request_events` table**                                                      | CC's mutable `comment` varchar; ZZ's jsonb array and its symbol/string-key bug                               |
| **`rejected` status with a reason**                                                    | neither had a way to say "no"                                                                                |
| **`executing` status + attempts table + claim-then-invoke**                            | double execution; FOR UPDATE held across HTTP                                                                |
| **Idempotency tokens + retry ceiling**                                                 | unbounded retries of non-idempotent side effects                                                             |
| **Error taxonomy**                                                                     | one rescued class; failed executions rendering a 500                                                         |
| **Guards shared by commands and presenters**                                           | UI/enforcement drift                                                                                         |
| **Presenters + JSON contract**                                                         | logic in templates; no API surface                                                                           |
| **Authorization adapter; gem-resolved permissions**                                    | the permission tautology; a hardcoded role model                                                             |
| **Polymorphic actors chosen per request, no FKs, snapshotted labels**                  | CC's typeless raw UUIDs; ZZ's single hardcoded `Member` FK; views breaking on a deleted actor                |
| **`payload_labels` + `title` snapshots**                                               | show pages going blank once the referenced record is destroyed                                               |
| **Visibility scoping applied to index *and* show**                                     | the cross-tenant IDOR                                                                                        |
| **ERB views + class contract + six-tier override story**                               | Haml dependency; Phlex/DaisyUI coupling; fork-to-customise                                                   |
| **Approver inbox scope** (`Request.awaiting_approval_from(actor)`)              | neither source could answer "what is waiting for me"                                                 |
| **Expiry, `expires_at`, sweeper**                                                      | requests pending forever                                                                                     |
| **Notifications: `config.on_event` + `ActiveSupport::Notifications`**                  | approvers never told a request exists                                                                        |
| **`executed_at` actually written**                                                     | rendered but permanently blank in ZZ                                                                         |
| **Host test kit** (§14)                                                                | neither shipped anything                                                                                     |
| **Pagination, filtering, sorting on index**                                            | dead `filter_by_state`; commented-out `pagy`                                                                 |
| **I18n throughout**                                                                    | hardcoded English                                                                                            |
| **Optional `ChangeRequests::Actor` concern**                                           | -                                                                                                            |
| **Maintenance rake tasks** (`expire`, `reap`, `verify`)                                | -                                                                                                            |

### Deliberately post-1.0

Delegation / proxy approval · escalation and reminder schedules · conditional routing rules ("> €10k needs
two approvals" - the registry can host it, but a rules DSL is a project of its own) · weighted or per-group
quorum · request templates / bulk approval · a transactional outbox beyond the attempts table · non-PostgreSQL
adapters · Phlex and ViewComponent renderer gems · an admin dashboard with metrics.

## 17. Porting guides

Both ship in `docs/porting/`, each with a schema diff, a data-migration sketch and a code-change checklist.

### 17.1 From the CC engine

| CC                                                                    | Gem                                                                       |
|-----------------------------------------------------------------------|---------------------------------------------------------------------------|
| `permission` (PG enum, one value)                                     | `action_key` in the registry; permissions move to `stage.permissions`     |
| `approver_id` (single column)                                         | one `change_request_approvals` row                                        |
| `comment` (append-only varchar)                                       | `change_request_events` rows                                              |
| `ChangeRequests::Approval.call(request_id:, actor_id:, permissions:)` | `Commands::Approve.call(request:, actor:)`                                |
| `config.permission_list`                                              | the registry                                                              |
| `config.current_actor_access_method = :current_admin`                 | `config.current_actor = ->(c) { c.current_admin }`                        |
| `config.permissions_access_method`                                    | `t.permissions` on each registered actor type                             |
| `config.routes = %i(…)`                                               | unchanged                                                                 |
| `change_requests:views` + fork                                        | `config.actor_label` / `datetime_format` / `payload_renderer` (Tiers 2–3) |
| Haml partials                                                         | ERB partials                                                              |

CC's three actor columns are bare UUIDs with **no type**, so the backfill must be told which class they
belonged to: `actor_type: "Admin"` for the whole table, since CC only ever had one. Labels are backfilled by
looking the actor up once, falling back to the raw UUID when the row is already gone - after which the
snapshot is authoritative and the lookup never happens again.

Data migration: derive `action_key` from a host-supplied `{ [service, action] => action_key }` mapping;
set `requester_type`/`executer_type` to the supplied class and cast the ids to string;
`INSERT INTO change_request_approvals SELECT … WHERE approver_id IS NOT NULL`; split `comment` on `\n` into
`commented` events with a null actor and `metadata: { imported: true }`; drop the two PG enum types last.
`ChangeRequests::Porting::CC.backfill!(mapping:, actor_type: "Admin")` ships as a documented, idempotent,
re-runnable task.

### 17.2 From the ZZ service

Structurally much closer; the work is renames, the registry, and events.

| ZZ                                          | Gem                                                                                      |
|---------------------------------------------|------------------------------------------------------------------------------------------|
| `ChangeRequest`                             | `ChangeRequests::Request`                                                                |
| `ChangeRequestApproval`                     | `ChangeRequests::Approval` (+ `change_request_stage_id`)                                 |
| `ChangeRequests::Approval` (service)        | `ChangeRequests::Commands::Approve`                                                      |
| `permissions` text[] + `required_approvals` | one `change_request_stages` row + `change_request_stage_permissions` rows per request     |
| `comments` jsonb                            | `change_request_events` rows                                                             |
| `organization_id` (FK)                      | `tenant_type` `"Organization"` + `tenant_id` string + `tenant_label` snapshot            |
| `belongs_to :requester, class_name: "Member"` | `requester_type` `"Member"` + `requester_id` string + `requester_label` snapshot; FK dropped |
| Phlex components                            | ERB partials + presenters (the component logic maps almost 1:1 onto `Presenter#actions`) |
| controller's `permissions` method           | deleted - the gem resolves permissions                                                   |

Data migration: one stage per request (`position: 1`, `rule: :n_of`, `threshold: required_approvals`,
`permissions:` copied); attach existing approvals to it; expand `comments` jsonb into event rows, mapping
labels (`comment`→`commented`, `failure_reason`→`execution_failed`, `cancelation`→`canceled`,
`unapproval`→`unapproved`) and reading with **string** keys, which is what the jsonb actually contains.

Then the actor migration: `requester_type = 'Member'` etc. across all four tables, ids cast to text, labels
backfilled from `members` in one pass, and **the foreign key constraints dropped**. Dropping the FKs is the
step that makes ZZ's members deletable without either blocking on the constraint or cascading the audit
trail away - worth doing in its own migration so it is obvious in the schema diff. Zazu registers `Member`
as its single actor type on day one and can add `User` or `Admin` later with no migration at all.

## 18. Milestones and effort

Sequenced so that each milestone is independently releasable and the risky work lands early. Estimates
assume one experienced developer familiar with both source implementations.

| #       | Version   | Scope                                                                                                                                                                                                        | Effort |
|---------|-----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| **M0**  | 0.1.0     | Engine skeleton, Zeitwerk, `Configuration` + `validate!`, gemspec runtime deps, dummy app, CI matrix, `rake ci`, headless + packaging specs. **The seam is proven before any domain code exists.**           | 3–4 d  |
| **M1**  | 0.2.0     | Migrations + all five models; statuses incl. `rejected`; terminal-state guard; readonly attrs; events table; guards; commands (approve/unapprove/reject/cancel/comment); `with_lock`; single-stage workflow. | 5–7 d  |
| **M2**  | 0.3.0     | Registry: allowlist, payload schema, workflow DSL, snapshot-on-create, `verify!`, `ChangeRequests.request!`, error taxonomy, `rake change_requests:verify`.                                                  | 4–5 d  |
| **M3**  | 0.4.0     | Execution: `executing` status, attempts, claim-then-invoke, idempotency tokens, retry ceiling, background mode, reaper, expiry sweeper. **Concurrency specs.**                                               | 4–5 d  |
| **M4**  | 0.5.0     | Actor-type registry, `ActorRef`, batch resolution, label snapshots, authorization adapter, `visible_scope`, tenancy, separation-of-duties flags, `ChangeRequests::Actor`.                                                                                     | 2–3 d  |
| **M5**  | 0.6.0     | Presenters, value objects, collection eager loading, `as_json` contract + schema snapshot spec.                                                                                                              | 3 d    |
| **M6**  | 0.7.0     | Engine UI: base + requests controllers, routes, ERB partial set, helper module, i18n, optional stylesheet, pagination/filter/sort, Turbo-optional responses, `bin/demo`, view + request specs.               | 6–8 d  |
| **M7**  | 0.8.0     | Generators (install, action, controller, views, scaffold_ui) + generator specs + the generate-on-a-real-app CI job.                                                                                          | 4 d    |
| **M8**  | 0.9.0     | Host test kit: `change_requests/rspec`, `Testing`, matchers, shared examples, factories, `docs/07_testing.md`.                                                                                               | 3–4 d  |
| **M9**  | 0.10.0    | Multi-stage M-to-N: `sequential`/`parallel`, `n_of`/`all_of`/`percent`/`any`, named approvers, stage rejection semantics, unapproval across stages, UI stage progress.                                       | 5–7 d  |
| **M10** | 0.11.0    | Notifications (`on_event`, `ActiveSupport::Notifications`), JSON API controller, maintenance tasks.                                                                                                          | 2–3 d  |
| **M11** | **1.0.0** | Docs set, both porting guides + backfill tasks, README with screenshots, CHANGELOG, semver policy, RBS in `sig/`, release.                                                                                   | 4–5 d  |

**Total: roughly 8–10 focused weeks**, or 4–5 months at one day a week. Be honest about this in the README's
roadmap; the graveyard in this niche is full of gems that promised more than one maintainer could sustain.

Note M9 (multi-stage) lands late even though the **schema supports it from M1**. That ordering is deliberate:
the tables and the `workflow` snapshot are cheap to get right up front and ruinous to retrofit, but the
staged *evaluation logic and UI* can wait until the single-stage path is battle-tested.

## 19. Cut line for 1.0

**In:** registry, staged schema, events, `rejected`, execution safety, presenters, ERB UI with the six-tier
override story, generators, host test kit, PostgreSQL-only, Rails 7.1–8.1.

**On other databases:** nothing ships and nothing is prepared - no adapter branches, no compatibility layer,
no second CI target. The only concession is the schema posture in §5.6, which costs nothing today and keeps
a future port from being a data migration. MySQL, MariaDB, SQLite and SQL Server are added if and when a
real adopter asks, and the answer until then is a plain no.

**Out, and say so plainly in the README:** delegation, escalation/reminders, a conditional-routing rules
engine, weighted quorum, bulk approval, non-PostgreSQL adapters, Phlex/ViewComponent satellites, an admin
dashboard, a full transactional outbox.

An explicit non-goals section is a feature. It is what tells an evaluator in ninety seconds whether the gem
fits - and it is what protects the maintainer from the scope creep that ended every incumbent.

## 20. Open decisions

1. **Minimum Ruby.** The skeleton declares `required_ruby_version >= 4.0.0` and pins `.ruby-version` to
   4.0.6. For a gem seeking adoption that excludes essentially the entire installed base.
   **Recommendation: `>= 3.2`**, CI matrix `3.2 / 3.3 / 3.4 / 4.0`, development on 4.0. Costs almost
   nothing - the code uses no 4.0-only syntax.
2. **Minimum Rails.** **Recommendation: `>= 7.1`** (7.1 is where `ActiveRecord::Base#with_lock` semantics,
   composite-key handling and `normalizes` are all settled). Drop to 7.0 only if a concrete adopter needs it.
3. **Do commands raise or return a Result?** **Recommendation: raise** the typed taxonomy - it matches both
   source implementations, matches `update!` semantics, and pairs naturally with one `rescue_from` in the
   controller. Revisit if a real adopter wants Results; adding `Commands::Approve.result(...)` later is
   additive and non-breaking.
4. **Is `parallel` stage mode needed at 1.0**, or is `sequential` enough? Sequential covers the common
   "peers, then owners" case. `parallel` is ~a day of extra evaluation logic and UI. Suggest shipping the
   column and the enum value at M1, and the behaviour at M9 only if wanted.
5. **Does the requester's own permission set gate creation**, or is any actor allowed to *request* anything
   registered? **Recommendation: registry-optional `a.request_permissions`**, defaulting to unrestricted —
   the approval gate is the control, and over-restricting creation makes the feature unusable.
6. **IP clearance for the CC lineage.** The CC engine was written on company time in a company
   repository. Even though this plan is a rewrite rather than a copy, the design lineage is direct. Get
   written sign-off before the first public push - it is cheap now and unfixable later.
7. **Label freshness: `:live` or `:snapshot` by default?** `:live` (prefer the current record, fall back to
   the snapshot) reads better - a renamed user shows their new name. `:snapshot` is stricter audit
   semantics: the page shows who they were *at the time*, which is what a compliance reviewer usually
   wants, and it never queries a host table. **Recommendation: `:live` as the default**, `:snapshot`
   documented as a one-line config for regulated hosts. Both are cheap because the snapshot is always
   written either way.

8. **Should `ActorRef#record` be memoised across a request?** Resolving lazily per ref is simple; memoising
   in a per-request identity map is faster but adds state. **Recommendation: no identity map** - the
   `CollectionPresenter` already batch-resolves by type, which covers the case that matters. Revisit only
   if a profile says otherwise.

9. **Gem name availability** on RubyGems for `change_requests` - confirm before M0 ends, since the name is
   baked into table names, the namespace and every doc.
10. **Announce the non-goal of record-diff approval loudly.** Nine of the ten existing gems approve an
   ActiveRecord diff; this one approves a command. Someone arriving from `approval` or `purgatory` needs to
   understand the difference in the first paragraph of the README, or the issue tracker fills with requests
   to become a different gem.
