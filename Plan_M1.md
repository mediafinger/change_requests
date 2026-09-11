# ChangeRequests — Implementation Plan for Milestone 1 (v0.2.0)

**Date:** 2026-09-10
**Source of truth:** [PLAN.md](PLAN.md) — §4, §5, §7 primarily. Section references below point there.
**Target release:** `0.2.0` (M1a + M1b in the §17 milestone table)

All decisions raised by the first draft of this document have been taken and folded back into PLAN.md.
§7 records them, §8 records the two questions closed afterwards, and §9 the thirteen issues found in
PLAN.md and their resolutions. Nothing in Milestone 1 is waiting on a decision.

---

## 1. Scope

Milestone 1 is two parts of the §17 table, as amended:

| Part    | Scope                                                                                                                                                                                 | Spec   | §17 estimate |
|---------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|--------------|
| **M1a** | Migrations for all nine tables, written as the install-generator template; models, indexes, CHECK constraints, readonly attrs, terminal-state guard, event immutability               | §4, §5 | 7 d          |
| **M1b** | Guards for the whole §7.2 table and commands for all of it except `Execute`; a minimal `Operations`/`Operation`; `with_lock`; sequential multi-stage single-quorum evaluation; errors | §7     | 11 d         |

**In scope for this document:** everything needed to get from the current repository state to a tagged
`0.2.0`, including the unfinished parts of **M0**, which is a hard prerequisite and is not started (§2).

**Explicitly out of scope** (later milestones, do not build here): the full `op.workflow` DSL, `op.cooldown`,
`verify!` and `ChangeRequests.request!` (M2); `Commands::Execute`, claim-then-invoke and the override branch
(M3a); background jobs, sweepers, reapers (M3b); `ActorRef`, batch resolution, `visible_scope` (M4);
presenters (M5); controllers and views (M6); generators (M7); the host test kit (M8); `all_quorums`,
one-quorum-per-approval and named-approver linking (M9a); cooldown (M9b); `awaiting_approval_from` (M9c);
notifications (M10).

### Definition of done for 0.2.0

1. `bundle exec rake ci` green - the specs plus every linter, architecture and security check the
   repository carries - per [AGENTS.md](AGENTS.md).
2. All nine tables migrate up **and** down cleanly on PostgreSQL 18, from the install-generator template,
   with `uuid` primary keys and `uuid` foreign keys throughout - there is no other variant (§5.7).
3. Every model in §5 exists with its validations, CHECK constraints, readonly guard, terminal-state guard
   and event immutability (update **and** destroy), each covered by a spec.
4. Every guard in the §7.2 table and every command except `Execute` exists for the sequential multi-stage,
   single-quorum case, raises the §7 error taxonomy, and is covered by a table-driven truth-table spec.
5. `spec/integration/headless_spec.rb` creates → approves → reaches `approved` with `Rails` undefined.
6. CHANGELOG entry, version bump to `0.2.0`.

---

## 2. Prerequisite: M0 is not started

The repository contains the output of `bundle gem` plus documentation. Concretely:

| M0 deliverable (§17)                       | Status | Evidence                                                         |
|--------------------------------------------|--------|------------------------------------------------------------------|
| Engine skeleton, `isolate_namespace`       | ❌      | no `lib/change_requests/engine.rb`                               |
| Zeitwerk loader                            | ❌      | `lib/change_requests.rb` is `require_relative` + an empty module |
| `Configuration` + `validate!`              | ❌      | no `configuration.rb`                                            |
| Gemspec deps (activerecord, activesupport) | ❌      | only `zeitwerk`; no `pg`, no `railties`, no `rspec-rails`        |
| Dummy app (`spec/dummy`)                   | ❌      | `spec/` holds one version spec                                   |
| CI matrix                                  | 🟡     | one Ruby, no PostgreSQL service, no `gemfiles/`                  |
| `rake ci`                                  | ✅      | `Rakefile` already defines it                                    |
| Headless + packaging specs                 | ❌      | absent                                                           |
| Error taxonomy (`errors.rb`)               | ❌      | only `ChangeRequests::Error`                                     |

Eight blocking tickets (M0-1 … M0-8, **5 days**) are included below.

---

## 3. Build order

```
M0-1 gemspec/deps ─┬─ M0-2 zeitwerk+prefix ─ M0-3 Configuration ─┬─ M0-6 dummy app ─┬─ M1a-2 migrations
                   └─ M0-4 errors                                └─ M0-5 engine     │
                                                                                    ▼
        M1a-1 Record base ──▶ M1a-2 migrations ──▶ M1a-3 Request ──▶ M1a-4 Stage/Quorum ──▶ M1a-5 eligibility
                                                        │                                          │
                                                        ├──▶ M1a-6 Approval/ApprovalQuorum ◀───────┘
                                                        ├──▶ M1a-7 Event
                                                        ├──▶ M1a-8 Attempt
                                                        └──▶ M1a-9 actor columns ──▶ M1a-10 schema specs
                                                                    │
                                                                    ▼
  M1b-0 Operations ─ M1b-1 Guards::Base ─ M1b-2 Authorization ─ M1b-3 Commands::Base ─ M1b-4 Create ─┬─ M1b-5 Approve
                                                                                                     ├─ M1b-6 Unapprove
                                                                                                     ├─ M1b-7 Reject
                                                                                                     ├─ M1b-8 Cancel
                                                                                                     ├─ M1b-9 Comment
                                                                                                     ├─ M1b-10 Expire
                                                                                                     ├─ M1b-11 Guards::Execute
                                                                                                     └─ M1b-12 EvaluateWorkflow
                                                                                                              │
                                                            M1b-13 i18n ─ M1b-14 truth tables ─ M1b-15 races ◀┘
```

---

## 4. Tickets — M0 prerequisites

### M0-1 — Runtime and development dependencies
**Spec:** §2 ("Runtime dependencies"), §15.6
**Depends on:** —
**Deliver:**
- Gemspec runtime deps: `activerecord >= 7.1`, `activesupport >= 7.1`, `zeitwerk >= 2.6`, `railties >= 7.1`
  (declared runtime; every `require "rails/…"` still behind `defined?(Rails::Engine)`).
- Dev deps: `pg`, `rspec-rails`, `database_cleaner-active_record`, `activejob`. No `sqlite3`, deliberately.
- `gemfiles/rails_8.1.gemfile` + `BUNDLE_GEMFILE` wiring, even with one matrix entry — M11 needs the shape.
- **First task of all:** confirm Rails 8.1 boots on Ruby 4.0.6 (**R1**). Ruby 4+ is fixed; if Rails 8.1
  cannot run on it, that is a finding to report, not a reason to drop the Ruby floor.

**Acceptance:** `bundle install` resolves under Ruby 4.0.6; `rake ci` still green.
**Est:** 0.5 d

---

### M0-2 — Entrypoint, Zeitwerk loader, table-name prefix
**Spec:** §2 ("Autoloading", "Table names are derived"), §3, §4
**Depends on:** M0-1
**Deliver:**
- `Zeitwerk::Loader.for_gem` over `lib/`, ignoring `lib/generators` and `lib/change_requests/rspec.rb`.
- **`loader.collapse` on `models/` *and* `presenters/`** — `models/request.rb` defines
  `ChangeRequests::Request`, `presenters/request_presenter.rb` defines `ChangeRequests::RequestPresenter`.
  Every other directory is a real namespace and is not collapsed.
- **`ChangeRequests.table_name_prefix = "change_request_"`**, defined in `lib/change_requests.rb` — i.e.
  before `engine.rb` loads, since `isolate_namespace` installs its own only
  `unless mod.respond_to?(:table_name_prefix)`. This also works headless, where no engine exists.
- `ChangeRequests.config`, `.configure`, `.loader`; `ChangeRequests::SYSTEM_ACTOR`.
- `eager_load!` in the test environment so a typo'd constant fails in CI.

**Acceptance:** specs assert `ChangeRequests::Request` resolves, `ChangeRequests::Models` does not exist,
`loader.eager_load` raises nothing, and `ChangeRequests.table_name_prefix == "change_request_"` both with
and without the engine loaded.
**Est:** 0.5 d

---

### M0-3 — `Configuration` + `validate!` (M1 subset)
**Spec:** §10, §9.1, §19
**Depends on:** M0-2
**Deliver** only the keys M1 reads — the rest are M4/M10 and stubbing them invites drift:
- `config.actor_type "Name" do |t| … end` with `key_type`, `label`, `permissions`, `may_request`,
  `may_approve`, `may_execute`. (`finder` and `path` are M4.)
- `config.tenant_type` — **singular** block form, matching `actor_type` (the plural `tenant_types` spelling
  is gone from PLAN.md).
- `config.actor_label_strategy` (`:live` default, `:snapshot` fallback); M1 only writes snapshots.
- `config.default_permission_match = :any`, `config.actor_identity = nil`
- `config.requester_may_execute = false`, `config.approver_may_execute = true`
- `config.only_record_rejections = false`, `config.default_max_attempts = 1`, `config.default_expires_in = nil`
- `config.authorization` defaulting to `Authorization::Permissions.new` (built in M1b-2)
- `config.requester_may_override = false` — an ordinary setting with an ordinary default (§19.18).
- **`requester_may_approve` does not exist**, in any form: no reader, no setter, no constant. Naming it
  implies the gem has an opinion that could be argued with, and it does not — `Guards::Approve` refuses the
  requester by identity and consults nothing (§19.17, issue **I5**).
- `ChangeRequests.config` memoised, never nil; `validate!` raises with actionable messages.

**Acceptance:** `validate!` message specs; `config` never nil before `configure`; re-registering an actor
type merges; assigning `requester_may_approve` raises `NoMethodError`, because the setting is absent.
**Est:** 1 d

---

### M0-4 — Error taxonomy
**Spec:** §7 ("Error taxonomy")
**Depends on:** M0-2
**Deliver:** `lib/change_requests/errors.rb` with the full tree in one pass, including the errors M1 does
not yet raise (`ExecutionError` family) and the newly added `ReadonlyAttribute`. Every `TransitionError`
carries `#request`, `#reason` (Symbol) and a translated `#message`.
**Acceptance:** spec asserts the ancestry of every class, and that a message is produced without I18n
configured (falling back to the symbol).
**Est:** 0.5 d

---

### M0-5 — Engine wiring
**Spec:** §1, §2, §20.1
**Depends on:** M0-2
**Deliver:** `lib/change_requests/engine.rb` behind `defined?(Rails::Engine)`, `isolate_namespace
ChangeRequests`, generator defaults, `config.validate!` in `after_initialize`. Empty
`ChangeRequests::Engine.routes.draw {}` so the packaging spec has something to assert. No controllers (M6).
**Acceptance:** dummy app boots; requiring `change_requests` without Rails defines no `Engine`; the
engine does **not** override `table_name_prefix` (regression spec for M0-2).
**Est:** 0.5 d

---

### M0-6 — Dummy app on PostgreSQL
**Spec:** §15.1
**Depends on:** M0-3, M0-5
**Deliver:**
- `spec/dummy` — real Rails app, PostgreSQL only, `database.yml` from `DATABASE_URL`.
- Three heterogeneous actor classes: `User` (uuid PK), `Admin` (bigint PK), `Manager` (string PK), plus
  `Organization` as tenant. The string `*_id` column (§5.7 consequence 1) is untestable without them.
- rspec-rails wiring, transactional fixtures, schema load task.
- CI: PostgreSQL 18 service container, `db:test:prepare`.

**Acceptance:** the dummy app boots in a spec; CI green with a database.
**Est:** 1 d
**Note:** demo targets (`Demo::UpdateRoles`, `Demo::ChargeCard`, `Demo::Explode`) and seeds wait for M2/M3.

---

### M0-7 — Headless, packaging and dependency-rule specs
**Spec:** §2 ("Dependency rule"), §15.4, §15.5
**Depends on:** M0-2
**Deliver:** the headless subprocess spec (extended by M1a-10 and M1b-14), the static check that no domain
file references `ActionController`, `ActionView` or `Rails`, and the §15.4 packaging spec.
**Acceptance:** all three green, and the static check *fails* when a `Rails.` reference is introduced.

**As built:** the static check began as a hand-rolled Prism checker and was replaced by
[archspec](https://github.com/crmne/archspec), which expresses §2's rule declaratively in `Archspec.rb` and
covers more - it caught `lib/change_requests.rb`, which the hand-rolled glob never matched. The checker and
its spec were deleted rather than kept alongside; two mechanisms for one rule is two places to drift.
**Est:** 0.5 d

---

### M0-8 — CI matrix and `rake ci`
**Spec:** §15.6
**Depends on:** M0-1, M0-6, M0-7
**Deliver:** the specs plus the repository's linters, static analysis and security checks, each as its own
`rake` task so a developer runs exactly what CI runs, and a matrix over `gemfiles/*`. Which checks share a
job is a question about queue time and runner setup rather than about the design - see §15.6.

There is no second schema job: gem-owned keys are uuids and nothing else (**D3**), so there is no alternative
migration shape to prove. `generators-on-a-real-app` stays a commented placeholder until M7, because it is
the one check that must *not* run against this repository's bundle.
**Acceptance:** green on a PR.

**As built:** the checks were grouped into two jobs - one that needs PostgreSQL and one that does not -
after seven separate jobs spent more time on checkout and `bundle install` than on checking anything.
Isolation was not lost with them: `RSpec::Core::RakeTask` shells out to a fresh process per task, so
`headless` is as Rails-free as a step as it was as a job.
**Est:** 0.5 d

---

## 5. Tickets — M1a: schema and models

> TDD per [AGENTS.md](AGENTS.md): failing spec first, `rubocop -A` on touched files, then `rake ci`.

### M1a-1 — `ChangeRequests::Record` abstract base
**Spec:** §2, §4, §5.7
**Depends on:** M0-6
**Deliver:**
- `abstract_class = true`, inherits `ActiveRecord::Base`, references no host constant.
- **No `self.table_name` anywhere except `Request`** — names derive from
  `ChangeRequests.table_name_prefix` (M0-2). `Request` carries the one exception,
  `self.table_name = "change_requests"`, because it would otherwise derive `change_request_requests`.
- Shared concerns under `lib/change_requests/models/concerns/`: `ReadonlyAttributes`,
  `TerminalStateGuard`, `Immutable`, `StringEnum`. **`ActorColumns` is M1a-9's**, whose acceptance needs the
  three dummy actor classes - it was listed under both tickets.

**Acceptance:** `Record.abstract_class?`; a spec enumerates all nine models and asserts each derived table
name matches §4, so a rename cannot pass silently; a spec asserts `Request` is the only model that sets
`table_name` explicitly.
**Est:** 0.5 d

---

### M1a-2 — Migrations for all nine tables, as the install-generator template
**Spec:** §4, §5.1–§5.6, §5.7; decision **D3**, risk **R2**
**Depends on:** M1a-1
**Deliver:** `lib/generators/change_requests/install/templates/migration.rb.tt` producing all nine tables in
dependency order, plus a thin spec-support migrator that runs it against the dummy database. Writing the
template first (**R2**) means M7 inherits a tested artefact instead of re-deriving one.

Order: `change_requests` → `change_request_stages` → `change_request_quorums` →
`change_request_quorum_permissions`, `change_request_quorum_eligible_actors` → `change_request_approvals` →
`change_request_approval_quorums` → `change_request_events` → `change_request_attempts`.

Requirements:
- **`id: :uuid` on every table**, and `type: :uuid` on every internal `references`
  (`change_request_id`, `change_request_stage_id`, `change_request_quorum_id`,
  `change_request_approval_id`). No install-time switch, no bigint branch, no `--primary-key-type` flag
  (§5.7, §19.11). The polymorphic `*_id` columns pointing at **host** records stay `string` - that is the
  one place a key is not a uuid, and deliberately so.
- **Internal FKs only**, `on_delete: :cascade`. No FK to a host table (§5.7 consequence 2).
- **No `idempotency_key` column** and **no `attempts_count` column** (§19.12, §19.13).
- **`tenant_type` / `tenant_id` / `tenant_label` are always created and always nullable** (§5.1).
- **All CHECK constraints**, named explicitly:

| Table                               | Constraint                                                                                                               |
|-------------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| `change_requests`                   | `status IN (8 statuses)`; `max_attempts >= 1`; `current_stage_position >= 1`                                             |
| `change_request_stages`             | `status IN ('pending','satisfied','closed','rejected')`; `satisfied_by IN ('any_quorum','all_quorums')`; `position >= 1` |
| `change_request_quorums`            | `status IN ('pending','satisfied')`; `permission_match IN ('any','all')`; `threshold >= 1`; `position >= 1`              |
| `change_request_quorum_permissions` | `permission IS NOT NULL OR actor_type IS NOT NULL`                                                                       |
| `change_request_approvals`          | `decision IN ('approved','rejected')`                                                                                    |
| `change_request_attempts`           | `outcome IS NULL OR outcome IN ('succeeded','failed','abandoned')`; `number >= 1`                                        |

  **`change_request_events.kind` gets no CHECK** — inclusion validation only (§19.16), because every later
  milestone adds kinds and a CHECK makes each one a host migration.
- **All indexes from §5.1–§5.5**, including the partial ones: `(expires_at) WHERE status IN
  ('pending','approved')`, `(overridden_at) WHERE NOT NULL`, `(change_request_quorum_id, name) WHERE name IS
  NOT NULL`.
- **`nulls_not_distinct: true`** on the unique index over `change_request_quorum_permissions
  (change_request_quorum_id, permission, actor_type)` — Rails 7.2+ supports the option on PostgreSQL, and
  without it PostgreSQL treats every NULL as distinct, so the "any permission / any actor type" rows can be
  inserted twice (**I3**).
- `jsonb` (never `json`), `default: {}, null: false` for `payload`, `payload_labels`, `metadata`.
- `change_request_events`: `created_at` only, **no `updated_at`**; actor triple `not null` (the `System`
  sentinel fills it, §19.15).
- Datetime precision 6 throughout.

**Acceptance:**
- `db:migrate` then `db:rollback` to zero leaves nothing behind.
- A spec asserts every gem-owned primary key and internal foreign key is `uuid`, so a hand-edited migration
  cannot reintroduce a mixed schema.
- A spec asserts the full index and constraint list by querying `pg_indexes` / `pg_constraint`, so a dropped
  index fails CI rather than a production query plan. It includes an explicit assertion that the permissions
  unique index is `NULLS NOT DISTINCT`.
- Each CHECK is proven by an `INSERT` that violates it.

**Est:** 2 d

---

### M1a-3 — `Request` model
**Spec:** §5.1, §5.7, §5.8
**Depends on:** M1a-2
**Deliver:**
- `STATUSES` / `FINAL_STATUSES`, inclusion validation, predicates, `final?`. String columns, not a Rails
  `enum` over a PG type (§5.7).
- Scopes: `pending`, `approved`, `open`, `expired_candidates`, `overridden`.
- Associations to the gem's own tables: `stages`, `approvals`, `events`, `attempts`.
- `current_stage` → `stages.find_by(position: current_stage_position)`.
- **Readonly guard** — the §5.1 list (now including `max_attempts`), enforced by an own `before_update`
  raising `ChangeRequests::ReadonlyAttribute`, **not** by `attr_readonly`, which silently discards the
  assignment unless the host app enables `raise_on_assign_to_attr_readonly` (**I4**).
- **Terminal-state guard** — `before_update` raising `AlreadyFinalized` when `status_was` is final. The
  transition *into* a final state is unaffected; appending events and attempts is a different row.
- `lock_version`; `StaleObjectError` → `ChangeRequests::StaleRequest` is mapped in `Commands::Base`.

**Acceptance:** a spec per readonly column asserting a **raise**, not a silent no-op; terminal-state spec per
final status × mutated column; a spec proving a `successful` request still accepts a new `Event`.
**Est:** 1 d

---

### M1a-4 — `Stage` and `Quorum` models
**Spec:** §5.2, §5.3, §5.9; decision **D4**
**Depends on:** M1a-3
**Deliver:**
- `ChangeRequests::Stage` → `change_request_stages`: statuses, `satisfied_by` inclusion, `position` and
  `name` unique per request, `pending`/`satisfied`/`closed` scopes, `closed?`/`open?`, ordered `quorums`.
- `ChangeRequests::Quorum` → `change_request_quorums`: statuses, `permission_match` inclusion,
  `threshold >= 1`, `name` nullable and unique-within-stage when present. No `rule` column — it never
  existed and is now gone from §4 and §6.9 (**I9**).
- **Name format validation** — `snake_case` declaration identifiers (§5.9), immutable after create.
- Label resolution: `change_requests.stages.<name>` / `change_requests.quorums.<name>` with
  `name.humanize` fallback; a null quorum name falls back to the stage label.

**Acceptance:** uniqueness at the DB level, not only the validation; i18n resolution and humanize fallback;
a null-named quorum returning the stage label.
**Est:** 0.75 d

---

### M1a-5 — Eligibility models
**Spec:** §5.3 ("Eligibility rows"); decision **D4**
**Depends on:** M1a-4
**Deliver:** `ChangeRequests::QuorumPermission` and `ChangeRequests::QuorumEligibleActor`, both write-once
via the `Immutable` concern, with the doubly-NULL validation mirroring the CHECK and `actor_type` validated
against the registered allowlist.
**Acceptance:** the §5.3 2×2 as a table-driven spec including the rejected `NULL/NULL` cell at both the
validation and constraint level; a duplicate `(quorum, NULL, "Admin")` row is rejected by the
`NULLS NOT DISTINCT` index.
**Est:** 0.5 d

---

### M1a-6 — `Approval` and `ApprovalQuorum` models
**Spec:** §5.4, §5.3; decision **D4**
**Depends on:** M1a-4, M1a-9
**Deliver:**
- `Approval`: `decision` inclusion, `decided_at` presence, approver actor triple + optional
  `approver_identity`, denormalised `change_request_id` validated against the stage's request.
- `ApprovalQuorum` → `change_request_approval_quorums`: write-once, unique on the pair, cascade-deleted with
  the approval (Unapprove deletes rows, §7.1).
- The unique index `(change_request_stage_id, approver_type, approver_id)` is the enforcement point;
  `RecordNotUnique` must still be caught (M1b-3).

**Acceptance:** a duplicate decision raises `RecordNotUnique` even with validations skipped; `User#7` and
`Admin#7` can both decide the same stage.
**Est:** 0.5 d

---

### M1a-7 — `Event` model (append-only)
**Spec:** §5.5
**Depends on:** M1a-3
**Deliver:**
- `kind` **inclusion validation, no CHECK** (§19.16); `operation_version` not null; `occurred_at` not null;
  `metadata` jsonb.
- **System sentinel** — `actor_type "System"`, `actor_id "system"`, `actor_label "System"`
  (`ChangeRequests::SYSTEM_ACTOR`), exempt from the registered-type allowlist. The actor triple is `not
  null` on every row, so no presenter or export has to branch on nil. The id is the word `system`, not `0`:
  `*_id` is a string column shared with string-keyed host actors, and `0` is a value one of those could
  legitimately hold (§5.5).
- **Immutability against both update and destroy** — `before_update` and `before_destroy` raising
  `ActiveRecord::ReadOnlyRecord` (§19 / **Q5**). The only path that removes events is the request's own
  `ON DELETE CASCADE`, which the gem never triggers.
- No `updated_at`; `record_timestamps` handled so Rails does not try to set one.
- The documented PG rule/trigger snippet goes into `docs/08_events_and_notifications.md` as prose.

**Acceptance:** update raises; destroy raises; the sentinel passes the allowlist while an unregistered
`"Robot"` does not.
**Est:** 0.5 d

---

### M1a-8 — `Attempt` model
**Spec:** §5.6
**Depends on:** M1a-3
**Deliver:** the model and table now (M1a covers all nine tables); the runner that writes rows is M3a.
Columns per §5.6 — **no token column** (§19.13, **I6**: the request id is the idempotency key and needs no
storage). `number` is `attempts.count + 1`, assigned under T1's lock in M3a; the unique
`(change_request_id, number)` index is what makes a double claim impossible, and it exists from this ticket.
`outcome` inclusion allowing NULL while in flight.
**Acceptance:** model validations; a spec asserts the unique index rejects a duplicate `number`.
**Est:** 0.25 d

---

### M1a-9 — Polymorphic actor columns
**Spec:** §5.7, §9.1
**Depends on:** M0-3, M1a-3
**Deliver:**
- An `ActorColumns` concern generating `requester_*`, `executer_*`, `approver_*`, `actor_*`, `tenant_*`
  accessors over the `(type, id, label)` triple.
- `*_type` validated against the registered allowlist plus the `System` sentinel; an unregistered class
  raises `UnknownActorType` **before** any `constantize` (§5.7 consequence 5).
- ~~`*_id` cast to `String` on write.~~ **Not needed**: the column is a string, so ActiveRecord already
  casts on assignment. The behavioural specs stay - a uuid, a bigint and a string key through one column -
  but an override that no spec can fail is worse than none.
- `ChangeRequests.actor_attributes(actor)` → `{ type:, id:, label: }`, snapshotting the label through the
  registered `label` lambda. The full `ActorRef` value object (`resolved?`, `deleted?`, `record`, `path`) is
  **M4** and is not built here.

**Acceptance:** the three dummy actor classes (uuid / bigint / string PK) round-trip through one column; an
unregistered class raises; a hard-deleted `Admin` leaves `requester_label` intact and readable.
**Est:** 0.75 d

---

### M1a-10 — Schema and model integration specs
**Spec:** §15.2 (models bullet), §15.5
**Depends on:** M1a-2 … M1a-9
**Deliver:** the schema-assertion spec (indexes, constraints, column types, nullability, defaults, derived
table names) and the extension of the headless spec to migrate and create a request with `Rails` undefined.
**Acceptance:** `rake ci` green; headless spec green in a subprocess.
**Est:** 0.5 d

---

## 6. Tickets — M1b: operations, guards, commands, evaluation

### M1b-0 — Minimal `Operations` and `Operation` (pulled forward from M2)
**Spec:** §6.4, §6.12, §5.10; decision **D1**
**Depends on:** M0-3
**Deliver** the smallest registry that makes M1 testable, and no more:
- `ChangeRequests.operations` → `Operations` with `define`, `[]`, `keys`, `clear` (for specs).
- `Operation` with `key`, `version` (mandatory), `service`, `method_name`, `payload_labels`, `idempotent`,
  `max_attempts`, `expires_in`.
- **`op.approvals permissions:/actor_type:/eligible_actors:/match:/required:`** — the §6.4 shorthand only,
  describing one stage with one quorum. It *describes*; `Commands::Create` materialises (**Q14**).
- **Spec isolation for both globals** (**Q13**). `ChangeRequests.config` and `ChangeRequests.operations` are
  memoised module state, and a mutation in one example is visible in the next — confirmed by probe. A
  `spec/support` helper snapshots and restores both around every example. M1a never needed it because it
  never mutated config; every M1b guard and authorization spec will. Two order-dependent failures have
  already cost a debugging round each, and both were found only by the full suite.

**Not here (stays M2):** the full `op.workflow` block DSL, `op.cooldown`, `op.override`, `verify!`,
`ChangeRequests.request!`, `rake change_requests:verify`.

**Acceptance:** all four §6.4 `op.approvals` forms produce the expected workflow *description* — one stage,
one quorum, the right threshold, permission rows and named approvers — asserted against the description
object, not the database (**Q14**; M1b-4 asserts the rows). A missing `version` raises `ConfigurationError`
at declaration time; an unknown key returns nil so guards can detect the undeclared case (§5.11). A spec
registers an actor type and an operation, and a second spec sees neither.
**Est:** 1 d

---

### M1b-1 — `Guards::Base`
**Spec:** §7, §5.11
**Depends on:** M0-4, M1b-0, M1a-*
**Deliver:**
- `(request:, actor:, **options)`; `allowed?`, `reason`, `check!`.
- The `:operation_undeclared` check lives here, **with `Comment` exempted** (§5.11 as amended, **I8**).
- Helpers: `config`, `operation`, `stage`, `same_person?` honouring `config.actor_identity` when set,
  `actor_ref`.
- One shared reason vocabulary of symbols; translations in M1b-13.

**Acceptance:** a shared example runs every guard against an undeclared operation: all refuse except
`Comment`, which allows.
**Est:** 0.5 d

---

### M1b-2 — `Authorization::Permissions` and the eligibility predicate
**Spec:** §9.2, §5.3
**Depends on:** M1b-1
**Deliver:**
- `Authorization::Permissions#allows?(actor:, quorum:)` — resolves the actor's permissions through their
  registered type's lambda, evaluates the quorum's permission rows under `permission_match` (`any` = at
  least one row matches; `all` = this actor satisfies every row), OR-ed with a named-approver row match.
- `Authorization::Callable` wrapping `->(actor:, request:, stage:, action:) {}`.
- This predicate is written **once**; M9c re-expresses it as the SQL of `awaiting_approval_from`.

**Acceptance:** the 2×2 (`actor_type` × `permission`, both nullable) × both match modes × all three dummy
actor classes, table-driven, with the table structured so M9c can drop the SQL in as a second subject.
`NULL/NULL` never matches.
**Est:** 1 d

---

### M1b-3 — `Commands::Base`
**Spec:** §7, §20.1
**Depends on:** M1b-1
**Deliver:**
- `.call(request:, actor:, **)` delegating to an instance; the body wrapped in `request.with_lock`.
- `emit(kind, body: nil, metadata: {})` — the **single** write path for events, stamping the actor triple
  (or `SYSTEM_ACTOR`), `occurred_at`, and `operation_version` read live from the declaration, falling back
  to the request's creation-time value when the operation is gone (the `Comment` and
  `operation_undeclared` cases, §5.5/§5.11). M10 hangs `config.on_event` and `ActiveSupport::Notifications`
  off this one method; leave the seam, build no hooks.
- Error mapping: `RecordNotUnique` → the command's own `TransitionError` (never a 500, §15.3);
  `StaleObjectError` → `StaleRequest`.
- Commands raise (§19.3) and never accept permissions from the caller (§7).

**Acceptance:** a spec asserts every event in the suite was written through `emit`; both error mappings have
regression specs.
**Est:** 0.75 d

---

### M1b-4 — `Commands::Create` and workflow materialisation
**Spec:** §7.2, §6.12 point 4, §5.2, §5.3; decision **D1**
**Depends on:** M1b-0, M1b-3
**Deliver:**
- Payload validated as a JSON object → `InvalidPayload` otherwise.
- Writes the request row: `operation_key`, `service`, `method_name`, `operation_version`, `payload`,
  `payload_labels`, requester triple, `requester_identity`, optional tenant triple, `max_attempts`,
  `expires_at`. No `idempotency_key` (§19.13).
- **`requester_identity`** (**Q17**): a new nullable column on `change_requests`, snapshotted through
  `config.actor_identity` by `Concerns::ActorColumns` (`actor_reference :requester, identity: true`), the
  same way the label is. Without it the requester-cannot-approve rule falls back to `(type, id)` and stays
  blind across actor classes - the hole §9.4 exists to close.
- **Refuses an incomplete declaration** (**Q19**): no `service`, or no `op.approvals` at all. Both problems
  are reported together. M2's `verify!` catches them at boot; this is the backstop.
- Requester's actor type must declare `may_request` (§19.4).
- **Materialises** stages → quorums → permission rows → eligible-actor rows from the resolved workflow in
  one transaction, write-once for the life of the request.
- Emits `requested`.

**Acceptance:** a multi-stage operation materialises the exact expected row graph - described by a
hand-built `Workflow` value object, since `op.workflow` is M2 and the description objects are already
public (**Q18**); **all four §6.4 `op.approvals` forms materialise the stage, quorum, permission and
eligible-actor rows they describe** (moved here from M1b-0, **Q14**); editing the declaration afterwards
changes nothing on the in-flight request; a non-object payload raises; an actor type without `may_request`
raises `NotAuthorized`.
**Est:** 1 d

---

### M1b-5 — `Guards::Approve` + `Commands::Approve`
**Spec:** §7, §7.2
**Depends on:** M1b-2, M1b-4
**Deliver:** the guard exactly as §7 lists it — `:operation_undeclared`, `:not_pending`, `:requester`,
`:stage_not_current`, `:already_decided`, `:not_permitted`, in that order, since order decides which reason
a user sees. The `:requester` branch is a **plain identity comparison**; there is no
`config.requester_may_approve` to read, in any form (**I5**, §19.17).
- **`:stage_not_current` means eligible elsewhere on this request, but not here** (**Q20**). §7's snippet
  compares `stage == request.current_stage`, which is vacuous — the guard's `stage` *is* the current one.
  §6.9's stage-three director is the case it exists for: "not your turn yet" is a different answer from
  `:not_permitted`'s "you cannot approve this at all".
- **`:already_decided` honours `config.actor_identity`** (**Q21**), so one human cannot decide the same
  stage twice through two registered actor classes (§9.4). The unique index still enforces only the
  `(type, id)` form, so the guard is deliberately stricter than the database behind it.

The guard exposes `eligible_quorums` and `countable_quorums`; in M1 they are equal, and M9a makes the latter
a strict subset under `all_quorums`. **The command builds the guard once** (**I7**), creates the approval,
links quorums and emits `approved`. **The `Commands::EvaluateWorkflow` call lands with M1b-12** (**Q22**):
until then an approval is recorded and counted, and nothing advances the stage.
**Acceptance:** one spec per reason; the happy path emits exactly one `approved` event; a requester
approving their own request raises `NotApprovable(reason: :requester)`.
**Est:** 0.75 d

---

### M1b-6 — `Guards::Unapprove` + `Commands::Unapprove`
**Spec:** §7.1, §7.2
**Depends on:** M1b-5
**Deliver:** permitted only to the actor who gave the decision, only while their own stage is still
reversible. Deletes the decision row and its quorum links, emits `unapproved`, re-runs `EvaluateWorkflow`.
Refused on a closed stage, an `approved` request, or any final status. Cooldown is M9b, so "reversible"
means `pending` in M1 — M9b adds `satisfied` and `rejected` inside the window (**Q27**).

**Delete the approval and let the database cascade take the links** (**Q15**). `ApprovalQuorum` includes
`Concerns::Immutable`, so `approval.quorums.destroy_all` — the obvious code — raises `ReadOnlyRecord`. The
links are write-once by design: they record what was true at decision time and are never re-derived.

- **The row goes; the trail does not.** `Event` is append-only, so the `approved` event stays beside the
  `unapproved` one. The `unapproved` event carries the stage, the decision that was retracted and the
  quorums it had counted toward, read before the delete — otherwise a request that gained and lost the same
  approval twice leaves two indistinguishable pairs in the timeline (§5.9).
- **Matched on `(type, id)` alone** (**Q23**), not on `config.actor_identity`. §9.4 uses the identity to
  decide who *counts* as one person when tallying approvers; retracting is about which row this actor
  wrote, and one actor undoing another's row would make the trail say something untrue.
- **Either decision may be retracted** (**Q24**), approval or rejection. Under the default a rejection
  makes the request `rejected` and `:not_pending` refuses anyway, so the path is reachable through
  `config.only_record_rejections`, where the workflow continues.

Reasons, in order: `:operation_undeclared`, `:not_pending`, `:not_the_approver`, `:stage_not_open`.
The `EvaluateWorkflow` re-run lands with M1b-12 (**Q22**).

**Acceptance:** re-approval after unapproval succeeds (proving the unique index does not strand the actor);
unapproval by a different actor raises `NotUnapprovable`.
**Est:** 0.5 d

---

### M1b-7 — `Guards::Reject` + `Commands::Reject`
**Spec:** §7.1, §7.2
**Depends on:** M1b-5
**Deliver:** eligible approver of the current open stage or the requester; **reason mandatory**; default
sets request `rejected` (final) + stage `rejected` + a `rejected` event.
`config.only_record_rejections = true` records the decision and event without short-circuiting, and the
unique index guarantees the rejector cannot later approve that stage.

- **The mandatory reason lives in the command, not the guard** (**Q25**). A Reject button is what *opens*
  the form that collects the reason, so a guard refusing without one could never let the button appear —
  and §7 has the presenter consult the same guard. `Commands::Reject` raises
  `NotRejectable(reason: :reason_required)` after the guard passes, so authorization is reported first.
  M1b-9's `Cancel` follows the same shape.
- **The rejection row is written in both branches** (**Q26**), so `change_request_approvals` stays the
  complete record of who decided what on each stage and the unique index behaves identically either way.
- Reasons, in order: `:operation_undeclared`, `:not_pending`, `:stage_not_current`, `:already_decided`,
  `:not_permitted` — mirroring `Approve`, so "not your turn yet" reads the same across guards.
- The `rejected` event's metadata carries `recorded_only`, because whether the workflow continued is the
  first thing an audit asks and it turns on a config flag that may since have changed.
- **`op.cooldown` will govern how final the stop is** (**Q27**, §19.20). A rejection stops the *stage*
  immediately; the *request* finalises once the window elapses. M1's cooldown is always `0`, so the two
  happen in the same breath and none of M1b-7's code changes — but the two writes are already separate
  statements, and M9b puts the window between them rather than restructuring the command.
**Acceptance:** both config branches; a missing reason raises; a second decision from the same actor raises.
**Est:** 0.5 d

---

### M1b-8 — `Guards::Cancel` + `Commands::Cancel`
**Spec:** §7.2
**Depends on:** M1b-3
**Deliver:** requester or any eligible approver — eligible for a quorum on **any** stage, not just the
current one (§7.2 preamble); any non-final status **except `executing`** (**Q28**); **reason mandatory**
(**Q9**), enforced by the command as in M1b-7 (**Q25**) and recorded in the `canceled` event body; sets
`canceled`.

- **`executing` is refused** (**Q28**). A status change cannot recall a target that is mid-flight, and
  writing a terminal status would leave M3a's execution unable to record its own outcome. Reason
  `:executing`; the stuck-execution reaper (§8) is what covers runs that never finish.
- **`:already_finalized` maps to `AlreadyFinalized` in `Guards::Base`** (**Q29**), beside each guard's
  declared class. A request that is already over is the same refusal whichever command met it, and the
  model's `TerminalStateGuard` raises exactly that with exactly that reason (§5.8).
- The `canceled` event is emitted **before** the status changes and its metadata records the status the
  request was cancelled out of — otherwise every such row would read `canceled`.
- `Guards::Base` gains `eligible_approver?` (any stage), beside `eligible_quorums` (current stage only).
  M1b-9's `Comment` uses the same predicate.
**Acceptance:** a stage-three approver may cancel a stage-one request; a final request raises
`AlreadyFinalized`; a missing reason raises.
**Est:** 0.5 d

---

### M1b-9 — `Guards::Comment` + `Commands::Comment`
**Spec:** §7.2, §5.5, §5.11
**Depends on:** M1b-3
**Deliver:** requester or any eligible approver — eligible on **any** stage, like `Cancel`; permitted
**always** — every final status, and **also when the operation is no longer declared** (§5.11 as amended).
Emits `commented` with the body and writes no request column, so the terminal-state guard is untouched. When
no live declaration exists, `emit` stamps the request's creation-time `operation_version`.

- **The body is mandatory** (**Q30**), refused with `NotAuthorized(reason: :body_required)`. An empty note
  is noise in a trail that can never be cleaned up. Same shape as M1b-7 and M1b-8: a required keyword at
  the call site, checked by the command after the guard.
- **`NotAuthorized` now carries `#request` and `#reason`** (**Q31**). `Guards::Base#check!` builds whichever
  class a guard declared with those two keywords, and `NotAuthorized` was a plain `Error` taking none — so
  Ruby folded them into the message and the reason vanished. `Refusal`, extracted from `TransitionError`,
  is included by both; the ancestry is unchanged, so §8's "may never" / "not yet" split survives.
**Acceptance:** commenting succeeds on a `successful` request, a `canceled` request, and a request whose
operation has been removed from the registry.
**Est:** 0.25 d

---

### M1b-10 — `Guards::Expire` + `Commands::Expire`
**Spec:** §7.2, §8
**Depends on:** M1b-3
**Deliver:** system-only; the event carries `SYSTEM_ACTOR` (`"System"` / `"system"` / `"System"`, §19.15).
Permitted when `pending` or `approved` and past `expires_at`; sets `expired`, emits `expired`. The sweeper
`Maintenance.expire_stale!` is **M3b** — this is the transition only.

- Reasons, in order: `:operation_undeclared`, `:not_system` (an actor was supplied at all), then
  `:already_finalized`, `:not_expirable`, `:not_expired`.
- **Every refusal is `NotAuthorized`** (**Q32**), apart from the shared `:already_finalized` mapping. The
  only caller is M3b's sweeper, whose query already filters on status and `expires_at`, so these branches
  are a floor beneath it and never a user-facing flash. No `NotExpirable` is added to §7's taxonomy.
- **`:not_expirable`, not `:not_pending`** (**Q33**), for a request that is `executing` or `failed` —
  `approved` is permitted too, so `:not_pending` would be a wrong symbol, and the symbol is the contract.
- A null `expires_at` never expires, which is the default until a host sets `config.default_expires_in` or
  `op.expires_in`.
**Acceptance:** an actor-supplied call raises `NotAuthorized`; a request not yet past `expires_at` raises;
the emitted event carries the sentinel actor.
**Est:** 0.25 d

---

### M1b-11 — `Guards::Execute` (guard only)
**Spec:** §7.2, §8; decision **D2**
**Depends on:** M1b-3
**Deliver:** the guard's approval-state and separation-of-duties branches — request `approved` (or `failed`
and retryable), `config.requester_may_execute` / `approver_may_execute`, operation declared. `retryable?`
counts `attempts` rows, not a column (§19.12). **`Commands::Execute`, claim-then-invoke and the §8.1
override branch are M3a** and are not built here; §17 has been amended to say so.
**Acceptance:** guard truth table over statuses × actor roles; a spec documents that `Commands::Execute` is
intentionally absent at 0.2.0.
**Est:** 0.5 d

---

### M1b-12 — `Commands::EvaluateWorkflow`
**Spec:** §7.1; decisions **D5**, **I10**
**Depends on:** M1b-5
**Deliver:** the evaluation command — an internal command with no actor, invoked only from `Approve`,
`Unapprove` and `Reject`, inside their lock. Named `ChangeRequests::Commands::EvaluateWorkflow`, replacing
the free-floating `advance_workflow!` and `lib/change_requests/workflow.rb` of the original §2 layout.
1. Recount the current stage's pending quorums (`linked approvals >= threshold`).
2. Stage satisfied under `any_quorum`.
3. `close_stage!` immediately (cooldown is M9b, so the window is always zero here).
4. `close_stage!` sets `closed_at` + status `closed`, emits `quorum_satisfied` and `stage_satisfied`, then
   **advances `current_stage_position` to the next stage, or sets the request `approved` when none remains**
   — the sequential advance ships now (**D5**), because deferring it would mean rewriting this command in
   M9a rather than extending it.

Counting is only via `change_request_approval_quorums` links, never re-derived (§5.3, §7.1). Closed stages
are immutable and there is no rollback into an earlier stage. `all_quorums`, one-quorum-per-approval and
named-approver linking are **M9a**; cooldown is **M9b**.

**A standing rejection outranks any number of approvals** (**Q27**, §19.20). Step 0 of the evaluation, before
any recount: a stage holding a rejection is `rejected` and cannot be satisfied; a stage that was `rejected`
and holds none any more returns to `pending`. That half ships here, because it is correct at every cooldown
value and costs one query — what M9b adds is the window between stopping the stage and finalising the
request, plus `rejected_at`, `CloseStageJob` and the `:stage_rejected` guard reason that only becomes
reachable once the window is non-zero.

**Acceptance:** 1-of-1, 2-of-N and N-of-N single-quorum stages; a three-stage sequential workflow reaching
`approved` only after the last stage closes; an approval landing on a non-current stage refused; a quorum
losing its threshold via unapproval clearing `satisfied_at` and keeping the request `pending`; an approval
on a closed stage raising.
**Est:** 1.25 d

---

### M1b-13 — Reason vocabulary and i18n
**Spec:** §7, §5.9
**Depends on:** M1b-5 … M1b-11
**Deliver:** `config/locales/en.yml` with every guard reason and `TransitionError` message, plus the
`change_requests.stages.*` / `change_requests.quorums.*` namespaces. Messages must work with I18n absent
(headless), falling back to the symbol.
**Acceptance:** a spec enumerates every reason symbol raised anywhere in the suite and asserts a translation
exists, so a new reason cannot ship untranslated.
**Est:** 0.5 d

---

### M1b-14 — Guard truth tables and command specs
**Spec:** §15.2
**Depends on:** all M1b
**Deliver:** one table-driven spec per guard — guard × status × actor role, one row per case (§15.2).
Command specs cover happy path, every guard rejection, event emission and workflow advancement. Extend the
headless spec to create → approve → `approved`.
**Acceptance:** every cell present; `rake ci` green.
**Est:** 1 d

---

### M1b-15 — Concurrency regression specs (the M1 subset)
**Spec:** §15.3
**Depends on:** M1b-14
**Deliver:** the races M1's code can actually lose — the execution races are M3a's:
1. Two concurrent approvals racing the last slot of a quorum: exactly one transitions the stage.
2. The same actor approving twice concurrently: `RecordNotUnique` surfaces as `NotApprovable`, not a 500.
3. Concurrent approve + unapprove: the final state is consistent with the surviving approval count.

Real threads, real connections, real PostgreSQL. Needs a minimal `Testing.in_parallel(n)`; the full host
test kit is M8.
**Acceptance:** each spec fails when `with_lock` is removed — prove the test has teeth.
**Est:** 0.75 d

---

## 7. Decisions taken

All five blocking decisions from the first draft are resolved and reflected in PLAN.md (§19.9–§19.16).

| ID     | Decision                                                                                                                                                                                                                                                                                                                                          | Where it landed in PLAN.md |
|--------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------|
| **D1** | **A minimal `Operations` + `Operation` is pulled forward into M1b** (ticket M1b-0): registry, the declaration attributes, and the `op.approvals` shorthand. M2 keeps the full `op.workflow` DSL, `op.cooldown`, `verify!` and `request!`.                                                                                                         | §17 table, §19.9           |
| **D2** | **`Guards::Execute` ships in M1b; `Commands::Execute` and the override branch ship in M3a.** The §17 rows for M1b and M3a now say so, so the table stops promising both.                                                                                                                                                                          | §17 table, §19.10          |
| **D3** | **Every gem-owned key is a uuid** - all nine tables and every foreign key between them - with no install-time choice, no `--primary-key-type` flag and no bigint variant. Supersedes the earlier "dummy app on uuid, one bigint CI job": one schema shape, one migration template, one set of specs. Host tables and `t.key_type` are unaffected. | §5.7, §19.11, §13          |
| **D4** | **`ChangeRequests::Quorum`, `QuorumPermission`, `QuorumEligibleActor`, `ApprovalQuorum`**, alongside `Stage`, `Approval`, `Event`, `Attempt` — all named in §3's constant table, none carrying an explicit `table_name` (see I2).                                                                                                                 | §2 layout, §3              |
| **D5** | **Sequential stage advance ships in M1b**; only the multi-quorum AND/OR logic waits for M9a.                                                                                                                                                                                                                                                      | §7.1, §17 table, §19       |

Schema and behaviour answers, all now in PLAN.md:

| Was  | Answer                                                                                                                                                                                                         | Where               |
|------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------|
| Q1–3 | **No `idempotency_key` column at all.** The request's own id is handed to targets declaring `change_request_id:`, and the `executing` claim prevents double execution.                                         | §19.13, §8          |
| Q4   | **No `attempts_count` column.** `change_request_attempts` rows are the count; `number` is `attempts.count + 1`.                                                                                                | §5.6, §8, §19.12    |
| Q5   | **Events block `destroy` as well as `update`.**                                                                                                                                                                | §5.5, ticket M1a-7  |
| Q6   | **Comments stay allowed on requests whose operation is undeclared.**                                                                                                                                           | §5.11, §7.2, §19.14 |
| Q7   | **`kind` is an inclusion validation, no CHECK constraint.**                                                                                                                                                    | §5.5, §19.16        |
| Q8   | **Tenant columns are always created and always nullable.**                                                                                                                                                     | §5.1                |
| Q9   | **`Cancel` requires a reason.**                                                                                                                                                                                | §7.2, §19.14        |
| Q10  | **System actor is a sentinel**: `type "System"`, `id "system"`, `label "System"`; the event actor triple is `not null`. The id is a word, not `0`, since `*_id` is shared with string-keyed host actors (Q12). | §5.5, §19.15        |

---

## 8. Open questions

**None.** The M1a review on 2026-09-11 raised three; all are answered and folded into the tickets they
affect - M1b-0 for Q13 and Q14, M1b-6 for Q15.

| ID      | Question                                                                                                                      | Answer                                                                                                                                                                                                                                      |
|---------|-------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Q11** | Does `Create` need a dedupe story now that `idempotency_key` is gone? Two identical submissions produce two pending requests. | **No, and it is not documented.** Rails developers know how to prevent accidental double submission, and a deliberate duplicate is a legitimate request that the approvers can cancel. Neither the README nor PLAN.md explains it.          |
| **Q12** | `SYSTEM_ACTOR` used `id "0"`, which a string-keyed host actor could legitimately hold.                                        | **Use the non-castable sentinel `"system"`.** §5.5 and §19.15 updated; tickets M1a-7, M1a-9 and M1b-10 follow.                                                                                                                              |
| **Q16** | Should the gem constrain `json` for hosts, or keep it a development pin? Raised by M1a-1.                                     | **Constrain it.** `spec.add_dependency "json", "~> 2.7"`. A `gemspec` directive in a Gemfile pulls runtime dependencies in too, so this pins the gem's own suite *and* every host - which a development pin never could. See §2 and §19.18. |
| **Q13** | Spec-level config isolation: `ChangeRequests.config` is memoised module state, and a mutation in one example is visible in the next - confirmed by probe. `ChangeRequests.operations` adds a second global. | **A `spec/support` helper that snapshots and restores both**, shipped with M1b-0. Same shape as the two order-dependent failures already hit. |
| **Q14** | M1b-0's acceptance required M1b-4's code: a registry can only *describe* a workflow, not materialise one.                     | **M1b-0 asserts the description; the materialisation assertion moves to M1b-4.**                                                                                                                                                            |
| **Q15** | `ApprovalQuorum` is `Immutable`, so `approval.quorums.destroy_all` raises `ReadOnlyRecord`.                                    | **Unapprove deletes the approval and lets the database cascade remove the links.** The obvious code is the wrong code, so M1b-6 says so.                                                                                                    |
| **Q17** | §9.4 uses `config.actor_identity` for the requester-cannot-approve rule, but only approvals carried an identity column. Raised by M1b-1. | **Add `requester_identity` to `change_requests`**, snapshotted by `Commands::Create`. Deferring it would need a second migration for hosts that had already installed. See §5.1 and §9.4. |
| **Q18** | M1b-4's acceptance wanted a multi-stage operation, but `op.workflow` is M2.                                                   | **Build the `Workflow` description by hand in the spec.** The description objects are public value objects, so the materialiser's multi-stage path is proved now; M2 adds only the DSL that produces such a description. |
| **Q19** | An operation could be declared with no `op.approvals`, producing a request with no stages that could never be approved.        | **`Commands::Create` refuses it**, with `ConfigurationError`, alongside a missing `service`. An approval gate with no approvers is a misconfiguration, not a fast path. |
| **Q20** | §7's `:stage_not_current` branch compares the current stage with itself. What does it actually test?                          | **Eligible for a quorum on another stage of this request, but not the current one** — §6.9's stage-three director. |
| **Q21** | Should `:already_decided` honour `config.actor_identity`?                                                                     | **Yes.** §9.4 uses the identity in place of `(type, id)` when counting distinct approvers, and deciding a stage twice is that same question. |
| **Q22** | M1b-5 is specified to call `Commands::EvaluateWorkflow`, which is M1b-12.                                                      | **The call lands with M1b-12**, together with the advancement specs. M1b-5's own acceptance asks only for the approval, the links and one `approved` event. |
| **Q23** | Should Unapprove honour `config.actor_identity`, letting one human retract through a second actor class?                       | **No.** §9.4 names two uses for the identity and retraction is neither; only the actor who wrote the row may take it back. |
| **Q24** | May Unapprove delete a `rejected` row, or approvals only?                                                                      | **Either decision.** Unapprove is "take back my decision on this stage". The default short-circuit makes the request final, so this is reachable through `config.only_record_rejections`. |
| **Q25** | Where does Reject's mandatory reason belong, given §7 has the presenter consult the same guard?                                | **In the command.** A guard refusing without a reason could never let the button that collects one appear. |
| **Q26** | Does the default (short-circuiting) rejection branch also write an approvals row, or only the event?                          | **Always write the row**, so the table tells one story and the unique index behaves the same either way. |
| **Q32** | Expire's refusals mix an authorization answer (`:not_system`) with state answers, but `refuses_with` names one class and there is no `NotExpirable`. | **`NotAuthorized` for all of them**, plus the shared `:already_finalized` mapping. Expire is internal; its guard is a floor beneath M3b's query, not a flash. |
| **Q33** | §7.2 permits Expire when `pending` **or** `approved`, so `:not_pending` would misname the refusal for `executing` and `failed`. | **Add `:not_expirable`** to the shared vocabulary. |
| **Q30** | §7.2 says Comment is permitted "always" and never calls its body mandatory. Blank body — refuse or record? | **Refuse**, with `:body_required`. An empty comment is permanent noise in an append-only trail. |
| **Q31** | `Guards::Base#check!` passes `request:`/`reason:` to the declared error class, but `NotAuthorized` was a plain `Error` and silently swallowed both. Found by M1b-9, the first guard to declare it. | **Extract `Refusal` from `TransitionError` and include it in `NotAuthorized` too.** Ancestry untouched; Create's message-only `fail NotAuthorized, "…"` still works. |
| **Q28** | §7.2 permits Cancel in any non-final status, which includes `executing` — where the target is actually running. | **Refuse while `executing`.** A status change cannot recall it, and a terminal status would leave the execution unable to record its outcome. Narrower than §7.2's wording, recorded there. |
| **Q29** | The acceptance wants `AlreadyFinalized`, but `refuses_with` names one error class per guard.               | **`Guards::Base` maps `:already_finalized` to `AlreadyFinalized`** for every guard; everything else raises the declared class. |
| **Q27** | A mistaken approval is retractable; a mistaken rejection killed the request outright, and `only_record_rejections` — whose purpose is to *not* stop anything — was the only mode where taking it back worked. | **Extend `op.cooldown` to rejection in M9b.** A rejection stops the stage at once and finalises the request only after the window, so `Unapprove` has something to undo. A stage with a standing rejection can never be satisfied; withdrawing the last one returns it to `pending`. At cooldown `0` nothing about M1 changes. See §5.2, §7.1, §7.2 and §19.20. |

---

## 9. Issues found in PLAN.md — all resolved

| ID      | Issue                                                                                               | Resolution in PLAN.md                                                                                                                                                                                                                                         |
|---------|-----------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **I1**  | Zeitwerk mapped `models/request.rb` to `ChangeRequests::Models::Request`, contradicting §3.         | `loader.collapse` on **both** `models/` and `presenters/`; stated in §2.                                                                                                                                                                                      |
| **I2**  | Relying on the engine's `table_name_prefix` would produce `change_requests_stages`, not §4's names. | `ChangeRequests.table_name_prefix = "change_request_"` defined before `engine.rb`; `change_request_stage_quorums` renamed to `change_request_quorums` so it derives; `Request` keeps the only explicit `table_name`. §2 and §4 updated, and M1a-1 asserts it. |
| **I3**  | The nullable unique index on quorum permissions allowed duplicate "any/any" rows.                   | `nulls_not_distinct: true` (Rails 7.2+ / PG 15+); §5.3 states the reason.                                                                                                                                                                                     |
| **I4**  | `attr_readonly` silently discards rather than raising, unless the host app opts in.                 | Own `before_update` guard raising `ChangeRequests::ReadonlyAttribute`, a new node in the §7 taxonomy. §5.1 rewritten.                                                                                                                                         |
| **I5**  | `Guards::Approve` read `config.requester_may_approve`, which §8 says is hard-wired false.           | The guard compares identity only, and the setting was removed outright rather than kept as a reader returning false or a setter that raises — see §19.17. `config.requester_may_override` became an ordinary setting defaulting to false (§19.18).            |
| **I6**  | §5.6's prose promised an attempts "token" column that the column list omitted.                      | Dropped from the prose.                                                                                                                                                                                                                                       |
| **I7**  | `Commands::Approve` built the guard twice and called an undefined `countable_quorums`.              | Built once; both `eligible_quorums` and `countable_quorums` are defined on the guard.                                                                                                                                                                         |
| **I8**  | §5.5 promised post-mortem comments; §5.11 refused every guard on an undeclared operation.           | `Comment` is exempt from the undeclared refusal; §5.11, §7.2 and the guard base updated.                                                                                                                                                                      |
| **I9**  | A phantom `rule` column appeared in §4 and §6.9 that §5.3 explicitly denied.                        | Removed from both.                                                                                                                                                                                                                                            |
| **I10** | Two `Workflow` constants — the evaluator and the declaration DSL.                                   | The evaluator is now `ChangeRequests::Commands::EvaluateWorkflow`; `workflow.rb` is gone from the §2 layout, and `CloseStageJob` moves to `execution/close_stage_job.rb`.                                                                                     |
| **I11** | `config.tenant_types` (§5.1, §9) vs `config.tenant_type` (§10).                                     | Singular everywhere.                                                                                                                                                                                                                                          |
| **I12** | §17 did not acknowledge M1's dependency on M2 and M4.                                               | Resolved by D1 and the M0-3 / M1a-9 scoping; the §17 rows for M0, M1a, M1b, M2, M3a and M9a were rewritten and re-estimated.                                                                                                                                  |
| **I13** | §19.4 was a question inside a decisions list.                                                       | Rewritten as a statement, tied to `t.may_request`.                                                                                                                                                                                                            |

---

## 10. Risks

| ID     | Risk                                                                          | Position                                                                                                                                 |
|--------|-------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| **R1** | Ruby 4.0.6 + Rails 8.1 compatibility is unverified.                           | **Ruby 4+ is fixed.** M0-1 verifies the combination as its first task; a failure is a finding to report, not a reason to drop the floor. |
| **R2** | The nine-table migration is written before the install generator exists (M7). | **Accepted and inverted:** M1a-2 *is* the generator template, run in specs by a support migrator. M7 inherits a tested artefact.         |
| **R3** | Schema mistakes become host migrations after 0.2.0.                           | **Downgraded.** There is no production data during development; migrations are cheap until the first real adopter.                       |
| **R4** | Guard/inbox predicate drift between M1b-2's Ruby and M9c's SQL.               | **Accepted.** Everything ships together at 1.0; M1b-2's table is structured so M9c can add the SQL as a second subject.                  |
| **R5** | The ticket sum is roughly twice §17's original M1 budget.                     | **Accepted.** §17's estimates have been raised to match: M0 5 d, M1a 7 d, M1b 11 d, and the overall total to 10–12 weeks.                |

---

## 11. Estimates

| Block                              | Tickets        | Days        |
|------------------------------------|----------------|-------------|
| M0 prerequisites                   | M0-1 … M0-8    | 5.0         |
| M1a — schema and models            | M1a-1 … M1a-10 | 7.25        |
| M1b — operations, guards, commands | M1b-0 … M1b-15 | 11.0        |
| **Total to 0.2.0**                 | **34 tickets** | **23.25 d** |

The §17 table now carries these numbers rather than the original 9–12 days, so the plan and the milestone
table agree. The largest single line is M1a-2 (2 d): the migration template is the artefact everything else
in the gem is built on, and the one place where being wrong is expensive after the first adopter.
