# ChangeRequests — Implementation Plan for Milestone 1 (v0.2.0)

**Written:** 2026-09-10 — **revised against the build:** 2026-09-11
**Source of truth:** [PLAN.md](PLAN.md) — §4, §5, §7 primarily. Section references below point there.
**Target release:** `0.2.0` (M1a + M1b in the §17 milestone table)
**Status:** 29 of 34 tickets merged (PRs #1–#36, `main`). Five remain: **M1b-11 … M1b-15**.

§7 records the five blocking decisions taken before the build started, §9 the thirteen issues found in
PLAN.md, and §8 the questions raised during the build — Q11–Q33 during M1a and M1b-1…M1b-10, and Q34–Q40
raised by this revision. **All are answered.** Nothing in the remaining five tickets is waiting on a
decision.

This document is now two things at once: a ticket list for the work that remains, and the record of what the
delivered tickets actually shipped. Where the build diverged from the ticket, the ticket carries an **As
built** note rather than being rewritten — the divergence is the finding, and erasing it loses it.

---

## 1. Scope

Milestone 1 is two parts of the §17 table, as amended:

| Part    | Scope                                                                                                                                                                                 | Spec   | §17 estimate |
|---------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|--------------|
| **M1a** | Migrations for all nine tables, written as the install-generator template; models, indexes, CHECK constraints, readonly attrs, terminal-state guard, event immutability               | §4, §5 | 7 d          |
| **M1b** | Guards for the whole §7.2 table and commands for all of it except `Execute`; a minimal `Operations`/`Operation`; `with_lock`; sequential multi-stage single-quorum evaluation; errors | §7     | 11 d         |

**In scope for this document:** everything needed to reach a tagged `0.2.0`, including **M0**, which was a
hard prerequisite and is now complete. §2 says where the build stands.

**Explicitly out of scope** (later milestones, do not build here): the full `op.workflow` DSL, `op.cooldown`,
`verify!` and `ChangeRequests.request!` (M2); `Commands::Execute`, claim-then-invoke and the override branch
(M3a); background jobs, sweepers, reapers (M3b); `ActorRef`, batch resolution, `visible_scope` (M4);
presenters (M5); controllers and views (M6); generators (M7); the host test kit (M8); `all_quorums`,
one-quorum-per-approval and named-approver linking (M9a); cooldown (M9b); `awaiting_approval_from` (M9c);
notifications (M10).

### Definition of done for 0.2.0

| # | Criterion                                                                                                                                                                          | State                                                                                                                           |
|---|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| 1 | `bundle exec rake ci` green - the specs plus every linter, architecture and security check the repository carries - per [AGENTS.md](AGENTS.md)                                     | ✅ 1130 examples, 0 failures, 4 pending                                                                                          |
| 2 | All nine tables migrate up **and** down cleanly on PostgreSQL 18, from the install-generator template, with `uuid` primary keys and `uuid` foreign keys throughout (§5.7)          | ✅                                                                                                                               |
| 3 | Every model in §5 exists with its validations, CHECK constraints, readonly guard, terminal-state guard and event immutability (update **and** destroy), each covered by a spec     | ✅                                                                                                                               |
| 4 | Every guard in the §7.2 table and every command except `Execute` exists for the sequential multi-stage, single-quorum case, raises the §7 error taxonomy, and is covered by a spec | 🟡 `Guards::Execute` outstanding (M1b-11); `Commands::EvaluateWorkflow` outstanding (M1b-12), so nothing advances a stage yet   |
| 5 | `spec/integration/headless_spec.rb` creates → approves → reaches `approved` with `Rails` undefined                                                                                 | 🟡 creates, materialises a stage and quorum by hand, and proves the terminal guard. The command layer is not exercised - M1b-14 |
| 6 | ~~CHANGELOG entry, version bump to `0.2.0`~~ | **struck (Q37)** — neither gates 0.2.0 while there are no installations. `VERSION` is already `0.2.0`; the CHANGELOG becomes a real gate at M11 |

The 4 pending examples are all the packaging spec skipping directories that do not exist yet; one of them,
`config/locales`, is M1b-13's and stops pending when that ticket lands. The other three are M6's.

**Five criteria, not six.** With item 6 struck, 0.2.0 is done when items 1–5 are — which means M1b-12 and
M1b-14 are the two tickets standing between the repository and the release.

---

## 2. Where the build stands

M0 and M1a are complete. M1b is complete through M1b-10. Everything below was built over 2026-09-09 …
2026-09-11 on `main`, one ticket per PR, with `rake ci` green at every merge.

| Ticket         | Scope                                                                                      | PR      | State                            |
|----------------|--------------------------------------------------------------------------------------------|---------|----------------------------------|
| M0-1 … M0-8    | deps, loader, config, errors, engine, dummy app, headless/packaging/architecture specs, CI | #1–#8   | ✅ merged                         |
| —              | archspec, brakeman, CI consolidated to two jobs, dummy-app boot fix                        | #9–#12  | ✅ **unplanned**, see M0-7 / M0-8 |
| M1a-1 … M1a-10 | `Record`, migration template, all nine models, actor columns, schema specs                 | #13–#23 | ✅ merged                         |
| M1b-0          | `Operations`, `Operation`, `Workflow` value objects, spec isolation                        | #24     | ✅ merged                         |
| —              | ADRs 0001–0014 in `docs/adr/`                                                              | #25     | ✅ **unplanned**, see M0-8        |
| M1b-1 … M1b-10 | `Guards::Base` … `Guards::Expire` + their commands                                         | #26–#36 | ✅ merged                         |
| —              | `change_request_stages.rejected_at` back-filled into the install template                  | #34     | ✅ **unplanned**, see M1a-2       |
| **M1b-11**     | `Guards::Execute` (guard only)                                                             | —       | ⬜ **outstanding**                |
| **M1b-12**     | `Commands::EvaluateWorkflow`                                                               | —       | ⬜ **outstanding**                |
| **M1b-13**     | reason vocabulary and i18n                                                                 | —       | ⬜ **outstanding**                |
| **M1b-14**     | truth tables, command specs, headless extension                                            | —       | ⬜ **outstanding**                |
| **M1b-15**     | concurrency regression specs                                                               | —       | ⬜ **outstanding**                |

**What this means in practice.** Every guard except `Execute` refuses correctly and every command except
`Execute` writes correctly — but **no approval advances anything**. `Approve`, `Unapprove` and `Reject` each
carry a comment where the `Commands::EvaluateWorkflow` call goes, deliberately (**Q22**). A request created
today collects approvals and stays `pending` forever. M1b-12 is the ticket that closes the loop, and it is
the only one of the five that changes shipped code rather than adding to it.

### 2.1 Work delivered that no ticket asked for

Four items shipped outside the ticket list. None was a scope creep argument at the time; each is recorded
here so the sum is visible and so §11's estimate is honest.

| What                                                            | Why it happened                                                                                        | Ticket it belongs against |
|-----------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|---------------------------|
| **archspec** replacing the hand-rolled Prism dependency checker | The hand-rolled glob never matched `lib/change_requests.rb`, the one file most able to break §2's rule | M0-7                      |
| **brakeman** + **bundler-audit** rake tasks and CI steps        | §15.6 says "security checks" and never named them; `rake ci` needed concrete tasks                     | M0-8                      |
| **CI consolidated from seven jobs to two**                      | Seven runners spent more time on checkout and `bundle install` than on checking                        | M0-8                      |
| **`docs/adr/` — fourteen records** | Plan_M1.md records decisions *ahead of* the code; nothing recorded them *once the code existed* | — maintainer-owned (**Q40**) |

---

## 3. Build order

Tickets marked ✅ are merged. The graph is kept as built, not pruned, because M1b-12 reaches back into
three of them.

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
  M1b-0 Operations ─ M1b-1 Guards::Base ─ M1b-2 Authorization ─ M1b-3 Commands::Base ─ M1b-4 Create ─┬─ M1b-5 Approve  ✅
                                    ✅               ✅                    ✅                ✅       ├─ M1b-6 Unapprove ✅
                                                                                                     ├─ M1b-7 Reject    ✅
                                                                                                     ├─ M1b-8 Cancel    ✅
                                                                                                     ├─ M1b-9 Comment   ✅
                                                                                                     ├─ M1b-10 Expire   ✅
                                                                                                     ├─ M1b-11 Guards::Execute
                                                                                                     └─ M1b-12 EvaluateWorkflow
                                                                                                              │
                                                            M1b-13 i18n ─ M1b-14 truth tables ─ M1b-15 races ◀┘
```

**The graph understates M1b-12.** It is drawn as a leaf of M1b-4, but it is the only remaining ticket that
**edits merged code**: `Commands::Approve`, `Commands::Unapprove` and `Commands::Reject` each hold a
placeholder comment where its call goes, and each of their command specs asserts today's non-advancing
behaviour. Those assertions have to change with it, in the same change set. Read its real shape as:

```
M1b-12 EvaluateWorkflow ──┬──▶ edits Commands::Approve   (+ its spec)
                          ├──▶ edits Commands::Unapprove (+ its spec)
                          ├──▶ edits Commands::Reject    (+ its spec, only_record_rejections branch)
                          └──▶ adds Stage#close_stage! path, quorum satisfied_at, request advance
```

---

## 4. Tickets — M0 prerequisites ✅ *all merged*

### M0-1 — Runtime and development dependencies
**Spec:** §2 ("Runtime dependencies"), §15.6
**Depends on:** —
**Deliver:**
- Gemspec runtime deps: `activerecord`, `activesupport`, `railties`, `zeitwerk >= 2.6`
  (declared runtime; every `require "rails/…"` still behind `defined?(Rails::Engine)`).
- Dev deps: `pg`, `rspec-rails`, `database_cleaner-active_record`, `activejob`. No `sqlite3`, deliberately.
- `gemfiles/rails_8.1.gemfile` + `BUNDLE_GEMFILE` wiring, even with one matrix entry — M11 needs the shape.
- **First task of all:** confirm Rails 8.1 boots on Ruby 4.0.6 (**R1**). Ruby 4+ is fixed; if Rails 8.1
  cannot run on it, that is a finding to report, not a reason to drop the Ruby floor.

**Acceptance:** `bundle install` resolves under Ruby 4.0.6; `rake ci` still green.
**Est:** 0.5 d

**As built:** the Rails floor is **`>= 8.1`, not `>= 7.1`.** §18 already cut the line at Rails 8.1, and a
7.1-compatible declaration the suite never exercises is a claim, not a support promise. `json ~> 2.7` was
added as a fourth runtime dependency (**Q16**), and a `# beware: json 3.0 is a breaking change` comment sits
beside it because the failure mode - ActiveSupport calling `JSON.parse` positionally - surfaces nowhere near
its cause. `nulls_not_distinct` (M1a-2, **I3**) needs Rails 7.2+ anyway, so 7.1 could never have shipped
the schema this plan specifies.

**R1 is closed:** Ruby 4.0.6 + Rails 8.1 resolve, boot and run the whole suite. No finding to report.

**Two dev dependencies are declared and not yet used:** `database_cleaner-active_record` (the dummy app uses
transactional fixtures instead, and the one spec that cannot - `headless` - builds and drops its own
database) and `activejob` (nothing enqueues until M3b/M9b). **Both stay** (**Q39**): DatabaseCleaner gets its
first user in M1b-15, whose specs cannot run inside a transaction, and ActiveJob gets one in M3b and again in
M9b's `CloseStageJob`. `spec/gemspec_spec.rb` asserts both are present, so removing either would be a
deliberate act rather than an oversight.

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

**As built,** three things the ticket did not name:
- **`Configuration#problems`** is public beside `validate!`, and `validate!` is one line over it. M2's
  `verify!` needs to *collect* problems rather than raise on the first, and `Operation` was given the same
  pair for the same reason. Every registered type contributes its own `problems`.
- **`config.authorization = <lambda>` coerces**, wrapping a bare `->(actor:, request:, stage:, action:)` in
  `Authorization::Callable` on assignment. §9.2 tells hosts to assign a lambda and the gem needs an object
  answering `allows?`; doing the conversion in the writer means `validate!` reports only things that answer
  neither. `Callable` itself was pulled forward from M1b-2 by this.
- **`initialize_copy` deep-dups** the actor and tenant registries and the authorization object, because
  `actor_type` reopens a registration in place - a shallow copy would share every mutation. M1b-0's spec
  isolation (**Q13**) is built on this being a real copy, so the two tickets are coupled more tightly than
  the graph shows.

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
`headless` is as Rails-free as a step as it was as a job. `if: ${{ !cancelled() }}` on every step after the
first keeps the failure overview the separate jobs gave.

**Two security checks were named, because §15.6 only said "security checks":**
- `rake brakeman` — `--force-scan` is mandatory on a gem: without it Brakeman refuses **and exits 0**.
  `--exit-on-error --exit-on-warn` because a warning is exit 3 and would otherwise read as a pass. The
  target is the gem root, not `spec/dummy`, which sees only fixture models. §6.12's dispatch constantizes a
  stored string and calls a method on it, which is exactly the shape `UnsafeReflection` and `Send` exist for.
- `rake bundle:audit` — wrapped in `tasks/bundle_audit.rb` rather than using the stock task, so it audits
  the **active** gemfile's lockfile. With `BUNDLE_GEMFILE` pointed at `gemfiles/rails_8.1.gemfile`, the stock
  task audits the wrong lockfile silently. `spec/tasks/bundle_audit_spec.rb` covers the command it builds.

**`docs/adr/` also landed here** (#25): fourteen records covering the decisions the code has already made.
They exist because this document records decisions *ahead of* the implementation and PLAN.md records the
design, and neither answers "why is the shipped code like this" for someone reading the repository. The
division is stated in `docs/adr/README.md`: an ADR describes the gem as it stands; PLAN.md holds decisions
still ahead of the code. Keeping them in step is **maintainer-owned and outside this plan** (**Q40**): no
ticket writes an ADR, and none of the five remaining tickets is blocked on one.
**Est:** 0.5 d

---

## 5. Tickets — M1a: schema and models ✅ *all merged*

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

**As built,** three additions the ticket's column lists did not carry:
- **`change_requests.requester_identity`** — **Q17**, raised by M1b-1 and folded into M1b-4, but the column
  had to be in this template. It is there.
- **`change_request_stages.rejected_at`** — **missed here and back-filled in #34**, a separate PR between
  M1b-8 and M1b-9. It is written from M9b and nothing reads it in M1, which is exactly why it was
  overlooked: a column with no code behind it has nothing to fail. It belongs in the first migration because
  every column not in it is a migration in every host application later, and that is the whole argument of
  ADR-0009. It is the one place M1a-2's acceptance was not strong enough: the schema spec asserts the indexes
  and constraints §5 names, and asserts nothing about columns §5 names that no model reads. **Decided
  (Q38): leave it.** No column-list spec is added. A column nothing reads is a column nothing breaks, and
  the miss cost one PR while the gem is unreleased — which is R3 behaving exactly as it was priced.
- **Two indexes not in §5's list**: `change_request_quorum_permissions(permission)` and
  `change_request_quorum_eligible_actors(actor_type, actor_id)`. Both are M9c's inbox query working
  backwards - "which quorums is this actor eligible for" - and both are free now and a host migration later.

**The acceptance held everywhere else.** `pg_indexes` / `pg_constraint` assertions caught two dropped
constraints during M1a-4 and M1a-5, and the `NULLS NOT DISTINCT` assertion is the only thing standing
between **I3** and a silently duplicated "any permission / any actor type" row.

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

**As built:**
- The `pending` / `approved` / `executing` / … scopes and the `pending?` / `approved?` / … predicates are
  **generated by `Concerns::StringEnum`**, not written on `Request`. One `string_enum :status, STATUSES`
  call produces a scope and a predicate per value and the inclusion validation; `Stage` and `Quorum` use the
  same concern for theirs. It also owns assignment, raising rather than reporting a validation error — which
  is what §5.7 wanted from a PG enum without the `ALTER TYPE` per value.
- **`retryable?` was not delivered.** §8's "`approved`, or `failed` and retryable" needs it and nothing in
  M1a reads it, so it fell between this ticket and M1b-11, which is where it now sits. It counts `attempts`
  rows rather than a column (§19.12), which is why it is a `Request` method and not a guard helper.
- `OPEN_STATUSES` was added beside `STATUSES` and `FINAL_STATUSES`, because `open` is `STATUSES -
  FINAL_STATUSES` and writing that list twice is how the two drift.

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

> **M1b-0 … M1b-10 are merged.** **M1b-11 … M1b-15 are the remaining work** and are the only tickets below still to be read as instructions rather than as history.

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

**As built:**
- **`ChangeRequests::Workflow` came back**, and **I10** needs re-reading because of it. I10 removed
  `workflow.rb` from the §2 layout on the grounds that two constants called `Workflow` - an evaluator and a
  declaration DSL - is one too many. That is still true, and the evaluator is still
  `Commands::EvaluateWorkflow`. But **Q18** then made the description objects public so M1b-4 could be
  specced without M2's DSL, and a description needs a name. `Workflow`, `Workflow::Stage`,
  `Workflow::Quorum` and `Workflow::Permission` are `Data.define` value objects under `lib/change_requests/`.
  The name is reused, the collision is not: nothing evaluates anything in that file.
- **`Operation#validate!` / `#problems`** mirror `Configuration`'s pair, and `Operations#define` calls
  `validate!` after yielding. The ticket only asked for a missing `version` to raise.
- **`op.approvals` refuses three more misconfigurations** than the ticket named, all at declaration time
  with `ConfigurationError`: no `permissions:`, `actor_type:` *or* `eligible_actors:` (a quorum nobody
  qualifies for can never be satisfied, and the request would sit pending until it expired); `required:`
  that is not an integer ≥ 1; and a `match:` outside `:any` / `:all`. These are M2's `verify!` work arriving
  early, and they arrived early because the alternative was materialising an unsatisfiable workflow in
  M1b-4 and discovering it in a spec that timed out.
- **`Workflow::Quorum#permission_match` and `Operation#max_attempts` / `#expires_in` resolve lazily** against
  `ChangeRequests.config`. Initializer order is the host's, and an operations file that loads before the
  configuration file must still see the host's defaults. `expires_in` distinguishes "never set" from "set to
  nil" with a separate flag, because `nil` there means *this operation never expires*, whatever the
  host-wide default says.
- **Spec isolation is copy-and-restore, not snapshot-and-restore** (**Q13**). `spec/support/global_state.rb`
  installs a `dup` of both memos around every example and puts the originals back after. Restoring a
  *snapshot* would have meant deep-copying on the way out instead of on the way in; copying on the way in
  means the original objects are never touched at all. It works only because `Configuration#initialize_copy`
  and `Operations#initialize_copy` are real deep copies (see M0-3).

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

**As built:** the predicate lives on `Authorization::Permissions` as specified, and `Guards::Base#qualifying`
is the single caller — every guard that asks "is this actor an eligible approver" goes through it, so there
is one place for M9c to compare its SQL against. The table is `spec/support/eligibility_examples.rb`, shared
between the authorization spec and the guard specs. `Authorization::Callable` shipped early with M0-3's
`authorization=` coercion (see there).

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

**As built:**
- **There is no `Guards::Create`**, and §7.2's table has a `Create` row. `Commands::Create` does the three
  checks inline: `UnknownOperation` for a missing declaration, `ConfigurationError` for an incomplete one,
  `NotAuthorized` for a class without `may_request`. The reason is structural — `Guards::Base` is
  `(request:, actor:)` and at create time there is no request.
- **`:may_not_request` is in `Guards::Base::REASONS` and nothing raises it.** `Commands::Create` raises
  `NotAuthorized` with a *message* and no `reason:`, so the symbol is unreachable and
  `NotAuthorized#reason` is nil on that path.

#### Decided (Q34) — raise the symbol here; the predicate is M6a's

**Edit `Commands::Create#refuse_unless_may_request`** to raise
`NotAuthorized.new(request: nil, reason: :may_not_request)`. `Refusal#initialize` already takes `reason:`
with a nil `request:`, and its `translated_message` falls back to the symbol, so the existing message can go
or stay as the first positional argument. One spec asserts `error.reason == :may_not_request`. This is the
whole of the M1 change, and it is what makes M1b-13's enumeration honest.

**No `Guards::Create` is built, in M1 or later.** A guard answers "may this actor do X *to this row*" and is
`(request:, actor:)` because of it. Create has no row, so a Create guard would either carry a second
signature — and `Guards::Base`'s one shape is what lets `spec/support/guard_examples.rb` run the same
example against every guard — or take a nil request and spend every branch defending against it. The
question is real; it is simply not a guard-shaped question.

**What M6a builds instead: `Operation#requestable_by?(actor)`.** §7's rule is that a presenter and a command
must not disagree, and for "raise a request" the thing they must agree on is a property of the *operation*
plus the actor's registered type — no request involved:

- the operation is declared (`ChangeRequests.operations[key]` is not nil),
- it is complete — a `service`, and a non-empty workflow,
- the actor's registered type declares `may_request`.

Those are exactly the three checks `Commands::Create` runs today, in the same order. **The predicate and the
command must read one implementation, not two**, or they drift into the disagreement §7 exists to prevent:
`refuse_incomplete` already collects its problems rather than raising on the first, so the natural shape is
for the completeness half to move onto `Operation` beside `#problems` — which is where M2's `verify!` needs
it anyway — and for both `Commands::Create` and `requestable_by?` to call it.

Deliberately **not** built in M1: nothing consults it before M6a, and M2's `verify!` will reshape
`Operation#problems` first. Recorded here so M6a inherits the decision rather than reopening it, and so M2
knows the completeness check has a second caller coming.
- `Create` overrides `around_perform` with `Record.transaction` rather than `with_lock`: there is no row to
  lock until it has written one, and the request plus its whole stage/quorum/permission/eligible-actor graph
  has to be all-or-nothing.
- **Eligible actors resolve to `(type, id)` here, not in the declaration.** `Workflow::Quorum` keeps the
  actor objects as the host wrote them, because resolving them would call `actor_attributes` from an
  initializer — before the file registering the actor types has necessarily run. `materialise_quorum` is
  where an unregistered class is finally refused.

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

**As built:** `Guards::Unapprove#decision` looks for the actor's row **on the current stage first and falls
back to their most recent row anywhere on the request**. The fallback is there for the refusal wording, not
for the retraction: an actor who decided on a stage that has since closed gets `:stage_not_open` — "too
late" — rather than `:not_the_approver`, which would be a lie. The command only ever destroys whatever
`decision` returned, and the `:stage_not_open` branch stops it before that on every closed-stage path.
M9b widens "reversible" to `satisfied` and `rejected` within cooldown; both are still the *current* stage,
because `close_stage!` is what advances the position, so the lookup does not change.

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

**As built,** and this is the finding that matters most for M1b-12: **at cooldown `0` the stage rejection
and the request rejection are two statements inside one lock, and nothing can ever observe the state
between them.** `Commands::Reject#stop` sets `stage.status = "rejected"` then `request.status = "rejected"`.
The request is now final, so `Guards::Unapprove` refuses with `:not_pending`, so the rejection cannot be
withdrawn. Under `only_record_rejections` the stage is never rejected at all. Between them, those two
branches mean **no sequence of public calls in M1 can produce a `pending` request whose current stage is
`rejected`** — which is the only state EvaluateWorkflow's step 0 exists to handle. See M1b-12 and **Q35**.

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

**As built:** the exemption is a class-level declaration, `exempt_from_undeclared_operation!`, read by
`Guards::Base#reason` — so the rule stays in the base and `Comment` states that it opts out, rather than
the base naming `Comment`. `spec/support/guard_examples.rb` runs the same example for every guard and
branches on the flag, so each guard reports the exemption it actually has instead of one of the pair being
skipped.

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
**Depends on:** M1b-3 ✅
**Deliver:** the guard's approval-state and separation-of-duties branches — request `approved` (or `failed`
and retryable), `config.requester_may_execute` / `approver_may_execute`, operation declared. **`Commands::Execute`,
claim-then-invoke and the §8.1 override branch are M3a** and are not built here; §17 has been amended to say so.

**Sharpened against the built guards.** Everything this ticket needs exists except two pieces:

1. **`Request#retryable?` has to be written here.** M1a-3 did not deliver it (see there). It counts
   `attempts` rows, not a column (§19.12): `attempts.count < max_attempts`. `max_attempts` is readonly after
   create and `>= 1` by CHECK, so there is no zero case to defend against. Put it on the model, not the
   guard — M3a's `Commands::Execute` and M3b's reaper both read it.
2. **Two reason symbols are already reserved and unused:** `:not_approved` and `:attempts_exhausted` sit in
   `Guards::Base::REASONS` waiting for this guard. Use them; do not invent new ones.

**Branch order**, following the built guards' convention that order decides which reason a user sees:

```
:operation_undeclared   (Guards::Base, free)
:already_finalized      (request.final?  → the shared REASON_ERRORS mapping, Q29)
:not_approved           (status is neither `approved` nor `failed`)                       ← Q42
:attempts_exhausted     (failed, but attempts.count >= max_attempts)
:not_permitted          (the actor's registered type declares may_execute = false)        ← Q43
:requester              (same_person?(request.requester, actor) and not config.requester_may_execute)
:not_permitted          (an approver on this request, and not config.approver_may_execute)
```

**Q42.** The original parenthetical for `:not_approved` — "not approved, and not (failed and retryable)" —
swallowed the exhausted-retry case and left `:attempts_exhausted` unreachable, contradicting the rationale
below it. `:not_approved` is the status question only; `:attempts_exhausted` is the ceiling question.

**Q43.** `config.actor_type … t.may_execute` (§9.1, default `true`) had no reader anywhere. It is checked
here, before the separation-of-duties branches, the way `may_approve` is checked inside
`Authorization::Permissions` — otherwise a class declared unable to execute would still pass the guard a
presenter consults.

`:already_finalized` earns its place before `:not_approved` because `successful` is final and "already done"
is a better answer than "not approved". `:attempts_exhausted` is split from `:not_approved` so a host can
tell a retry that ran out from a request that was never approved.

`refuses_with NotExecutable` — the class exists in the taxonomy and nothing raises it yet.

**Separation of duties is the one part with no precedent in the merged guards.** `Approve` refuses the
requester by identity and consults no setting (**I5**); `Execute` refuses the requester *unless*
`config.requester_may_execute`, which defaults to `false`. Use `same_person?` for it, the same helper, so
the two rules answer "is this the same human" identically — including through `config.actor_identity`.
"An approver on this request" means they wrote a row in `change_request_approvals`, not that they are
*eligible* to: `approver_may_execute` is about who actually decided, and it defaults to `true`.

**Acceptance:** guard truth table over statuses × actor roles × both separation-of-duties settings; a
`failed` request at and below its attempt ceiling; a spec documents that `Commands::Execute` is
intentionally absent at 0.2.0, so a reader of the 0.2.0 gem finds the gap stated rather than inferred.
**Est:** 0.5 d — unchanged; `retryable?` is a method and its spec.

---

### M1b-12 — `Commands::EvaluateWorkflow`
**Spec:** §7.1; decisions **D5**, **I10**
**Depends on:** M1b-5 ✅, M1b-6 ✅, M1b-7 ✅ — **it edits all three**
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
are immutable and there is no rollback into an earlier stage. One-quorum-per-approval and named-approver
linking are **M9a**; cooldown is **M9b**.

**`all_quorums`'s satisfaction rule ships here** (**Q44**), not with M9a. The column value is already valid,
`Stage#all_quorums?` already exists and M1b-4 already materialises such stages — so an evaluation that knew
only `any_quorum` would close "1 Admin AND 2 Owners" on the Admin alone, silently and green. It is one line
beside the `any_quorum` branch. M9a still owns what it actually owns: the *linking* rule that stops one
person holding both roles closing two quorums. It also makes the acceptance's "quorum losing its threshold"
case reachable through the public API, since under `any_quorum` a stage closes the instant a quorum is met.

**A standing rejection outranks any number of approvals** (**Q27**, §19.20). Step 0 of the evaluation, before
any recount: a stage holding a rejection is `rejected` and cannot be satisfied; a stage that was `rejected`
and holds none any more returns to `pending`. That half ships here, because it is correct at every cooldown
value and costs one query — what M9b adds is the window between stopping the stage and finalising the
request, plus `rejected_at`, `CloseStageJob` and the `:stage_rejected` guard reason that only becomes
reachable once the window is non-zero.

**Three merged commands change with it.** Each holds a placeholder comment where the call goes, and each of
their specs asserts today's non-advancing behaviour. Those assertions are not regressions to preserve; they
are scaffolding to remove, in this change set:

| Call site             | Where                                         | What the call does                                              |
|-----------------------|-----------------------------------------------|-----------------------------------------------------------------|
| `Commands::Approve`   | after `emit(:approved, …)`, inside the lock   | recount, possibly close the stage and advance or approve        |
| `Commands::Unapprove` | after `emit(:unapproved, …)`, inside the lock | recount; a quorum that lost its threshold clears `satisfied_at` |
| `Commands::Reject`    | the `only_record_rejections` branch **only**  | the workflow continues, so the stage may still be satisfied     |

`Commands::Reject`'s default branch does **not** call it: `stop` has already set the request `rejected`,
and re-entering evaluation on a final request is at best a wasted query. Its own comment says as much today.

**Step 0 has no reachable path in M1, and the ticket has to say so rather than discover it in a spec.**
§7.1 step 0 handles a `pending` request whose current stage holds a standing rejection. At cooldown `0` —
all of M1 — `Commands::Reject` writes the stage rejection and the request rejection in the same lock
(M1b-7), so that state never exists; under `only_record_rejections` no stage is ever rejected. Step 0 is
therefore **correct, cheap, and unreachable through the public API until M9b**. **Decided (Q35): ship it
now** — it is correct at every cooldown value, costs one query, and M9b extends this command rather than
rewriting it. Two consequences to honour:
- **spec it by writing the stage status directly**, and say in the spec that the state is unreachable
  through the commands in M1. A spec that looks like it drives a public path but does not is worse than one
  that admits what it is doing.
- do **not** add `rejected_at` writes here. The column exists (M1a-2) and M9b owns it, together with
  `CloseStageJob`, the window, and the `:stage_rejected` guard reason that only becomes reachable with it.

**What `close_stage!` owns.** §7.1 gives it four writes and the built code has none of them yet:
`closed_at` + status `closed` on the stage; `satisfied_at` + status `satisfied` on each quorum that met its
threshold; **one `quorum_satisfied` per such quorum, then one `stage_satisfied`** (**Q41**); then
`current_stage_position + 1`, or the request to `approved` when no stage remains.

**`stage_closed` no longer exists** — it was declared in `Event::KINDS`, emitted by nothing, and is removed
(**Q41**). M9b adds it back if `op.cooldown` ever puts a window between satisfaction and closing. Emit the
pair even for a single-quorum stage: the two kinds answer different questions, and branching on quorum count
here is how the multi-quorum case in M9a ends up with its own code path. Both events go through `Commands::Base#emit`, which stamps the
`SYSTEM_ACTOR` triple when `actor` is nil — and an evaluation triggered by an approval has no actor of its
own, so **these events are attributed to System.** **Decided (Q36): that is correct, and no actor is
threaded through.** Closing a stage is the gem's own act, not the approver's; the approvals that caused it
are already in the trail, each with its own actor, so a timeline reading "System closed the stage" sits
directly beneath the rows naming everyone who approved. Consistent with §19.15 and with `Expire`. M5 and M6b
render it that way rather than attributing the close to the last approver.

**`stage_satisfied` names the quorum that closed it** (§7.1). With one nameless quorum per stage there is
no name to give, so follow `Commands::Approve#metadata_for`: omit the key rather than emit a null.

**Acceptance:** 1-of-1, 2-of-N and N-of-N single-quorum stages; a three-stage sequential workflow reaching
`approved` only after the last stage closes; an approval landing on a non-current stage refused; a quorum
losing its threshold via unapproval clearing `satisfied_at` and keeping the request `pending`; an approval
on a closed stage raising; **the `only_record_rejections` branch advancing past a rejected-but-recorded
decision**; **step 0 driven by a directly-written stage status, labelled as such**; and the three edited
command specs no longer asserting that nothing advances.
**Est:** 1.25 d → **1.5 d**, for the three call sites and their specs.

---

### M1b-13 — Reason vocabulary and i18n
**Spec:** §7, §5.9
**Depends on:** M1b-5 ✅ … M1b-11
**Deliver:** `config/locales/en.yml` with every guard reason and `TransitionError` message, plus the
`change_requests.stages.*` / `change_requests.quorums.*` namespaces. Messages must work with I18n absent
(headless), falling back to the symbol.

**Sharpened: the lookup side already shipped; only the locale file is missing.**
- **`ChangeRequests::Translation`** is the single lookup path — `translate(key, default:)`, with
  `available?` guarding on `defined?(I18n)`. Every caller passes a usable default, which is why the suite is
  green with no locale file at all and why the headless spec can assert
  `error_message=requester`: with nothing to look up, the message *is* the reason symbol.
- **The keys are already fixed by the code.** `Refusal::I18N_SCOPE` is `"change_requests.errors"` and
  `Refusal#i18n_key` is `"change_requests.errors.#{reason || error_key}"`, where `error_key` is the error
  class underscored (`NotApprovable` → `not_approvable`) for the callers that raise without a reason. So the
  file needs **one key per entry of `Guards::Base::REASONS`** plus **one per `Refusal`-including error
  class** as the no-reason fallback. `Stage#label` and `Quorum#label` already read
  `change_requests.stages.<name>` / `change_requests.quorums.<name>` with a `humanize` fallback.
- ~~**The engine has to add the load path.**~~ **It does not** (**Q46**): `Rails::Engine` defines
  `paths["config/locales"]` and an initializer that appends it to `I18n.load_path`, so creating the
  directory is the whole of it — verified by probe before writing any engine code.
  `spec/integration/packaging_spec.rb`'s **pending** example for `config/locales` is this ticket's
  tripwire; it turns green on the directory existing, and the file has to be `git add`ed for it to,
  because the gemspec's file list comes from `git ls-files`.
- **Every entry of `REASONS` will have a raiser by the time this lands.** `:not_approved` and
  `:attempts_exhausted` become reachable with M1b-11; `:may_not_request` becomes reachable with M1b-4's
  one-line amendment (**Q34**). If M1b-4 has not been amended when this ticket starts, amend it here — the
  enumeration below is what makes the gap visible, and it is two words.

**`Commands::Create` raises the reason and no message** (**Q45**). Its message named
`t.may_request` — a configuration key the requester reading the flash can do nothing about. The reason is
set so a host still branches on it; the wording comes from the locale file.

**The message assertions were order-dependent** (**Q47**). `spec/change_requests/error_spec.rb` loads only
`spec_helper`, but `I18n.load_path` is process-wide: once any spec boots the dummy app the engine puts the
gem's locale file on it, so "the message is the symbol" passed or failed depending on which files ran
first. The fallback claims now use reasons nothing will ever translate, which holds either way.

**Acceptance:** a spec enumerates every reason symbol raised anywhere in the suite and asserts a translation
exists, so a new reason cannot ship untranslated — **and the reverse**, that every entry of `REASONS` is
either raised somewhere or deliberately absent with a note, so the vocabulary cannot accumulate dead
symbols. The headless spec keeps asserting the bare-symbol fallback, because a locale file now existing must
not become a thing the domain core needs.
**Est:** 0.5 d

---

### M1b-14 — Guard truth tables and command specs
**Spec:** §15.2
**Depends on:** all M1b
**Deliver:** one table-driven spec per guard — guard × status × actor role, one row per case (§15.2).
Command specs cover happy path, every guard rejection, event emission and workflow advancement. Extend the
headless spec to create → approve → `approved`.

**Sharpened: this ticket was written as if the guards would arrive untested, and they did not.** TDD per
[AGENTS.md](AGENTS.md) meant every guard and command shipped with its own spec file, one per reason branch —
roughly 240 examples across `spec/change_requests/guards/` and `spec/change_requests/commands/`, plus
`spec/support/guard_examples.rb` (the §5.11 exemption, run against every guard) and
`spec/support/eligibility_examples.rb` (M1b-2's 2×2). What is left is the part per-ticket TDD structurally
cannot produce:

1. **The headless extension — create → approve → `approved`.** This is DoD item 5 and the only one of the
   six that is nobody else's ticket. `spec/integration/headless_script.rb` today creates a request and
   hand-builds a stage and a quorum with `create!`; it never loads a command. Rewrite that half to
   `Commands::Create` → `Commands::Approve` → assert `approved`, which also makes it the first proof that
   the command layer needs no Rails. **It cannot be written before M1b-12**, because nothing reaches
   `approved` until then.
2. **Cross-guard consistency, which a per-guard spec cannot see.** One table over *every* guard × status ×
   actor role, asserting that the same situation gets the same reason from each guard that has an opinion
   about it. The branch orders were chosen deliberately to line up — `Reject` mirrors `Approve` so "not your
   turn yet" reads the same — and nothing currently fails if one of them drifts.

   **They had drifted** (**Q48**). For all four final statuses `Approve`, `Unapprove` and `Reject` answered
   `:not_pending` while `Cancel`, `Execute` and `Expire` answered `:already_finalized` — so a host rescuing
   `AlreadyFinalized` to mean "this request is over" caught three commands and missed three. The three
   decision guards gained an `:already_finalized if request.final?` branch ahead of their `:not_pending`
   one, which now means what it says: open, but not open for decisions.

   **Scope** (**Q49**): the status axis is written out cell by cell — 56 cells, the axis every guard has an
   opinion about — and the actor-role axis is asserted as **cross-guard rules** rather than a third
   dimension. The per-guard files already cover roles in ~240 examples, and a 400-cell table tends to get
   regenerated from the code it is meant to check.
3. **Nothing for the `emit` invariant — it shipped with M1a-7.** `spec/change_requests/event_spec.rb`
   proves it by **scanning the source** rather than the exercised paths: it greps every file under `lib/`
   for an event write and asserts `Commands::Base#emit` is the only match, with two companion examples
   proving the scan covers the tree and that the pattern matches the write it guards. That is stronger than
   M1b-3's runtime wording, and it means **M1b-12's `quorum_satisfied` and `stage_satisfied` events must go
   through `emit` or the spec fails** — which is the right failure.

**Acceptance:** headless reaches `approved` with `Rails` undefined; the cross-guard table has every cell;
`rake ci` green.
**Est:** 1 d → **0.75 d**, since the per-guard tables landed with their tickets.

---

### M1b-15 — Concurrency regression specs (the M1 subset)
**Spec:** §15.3
**Depends on:** M1b-14, and **hard on M1b-12**: races 1 and 3 are about stage *transitions*, and nothing
transitions a stage until EvaluateWorkflow lands
**Deliver:** the races M1's code can actually lose — the execution races are M3a's:
1. Two concurrent approvals racing the last slot of a quorum: exactly one transitions the stage.
2. The same actor approving twice concurrently: `RecordNotUnique` surfaces as `NotApprovable`, not a 500.
3. Concurrent approve + unapprove: the final state is consistent with the surviving approval count.

Real threads, real connections, real PostgreSQL. Needs a minimal `Testing.in_parallel(n)`; the full host
test kit is M8.

**Sharpened: the suite's default isolation is the obstacle.** Every other spec runs inside a transaction
that is rolled back, and a second thread on a second connection cannot see uncommitted rows — so these three
examples have to opt out of transactional fixtures and clean up after themselves, the way
`headless_script.rb` already does by building and dropping its own database. That is the reason
`database_cleaner-active_record` is in the gemspec and unused (M0-1): **this is its first user** (**Q39**).
Truncation between examples, scoped to the examples that opted out — the rest of the suite keeps its
transaction and never pays for it.

`spec/support/global_state.rb` installs a `dup` of the config and operations memos per example, on the main
thread. Spawned threads read the same module-level ivars, so they see the copy — but a thread that mutates
config would be mutating the example's copy from under the main thread. Race specs should register what they
need before spawning and treat the registry as read-only inside the threads.

Race 2 — the same actor approving twice — is the only one of the three that is **testable today**:
`Commands::Approve` already declares `on_conflict NotApprovable, reason: :already_decided`, and the unique
index already enforces it. It can be written before M1b-12 and is the cheapest proof that
`Testing.in_parallel(n)` works at all.

**Acceptance:** each spec fails when `with_lock` is removed — prove the test has teeth. Removing
`on_conflict` from `Commands::Approve` must turn race 2 into a `RecordNotUnique`, not a pass.

**The teeth are a measurement, not a removal** (**Q50**). Taken literally, "assert the race breaks without
the lock" is a spec that can pass by luck and fail the build on a slow morning — the interleaving is the
scheduler's to choose. Instead both probes measure the thing `with_lock` exists to control: **were two
command bodies ever inside at the same time?** With the lock, never; with it removed and the body held open
50ms, always. Both directions are deterministic, both run in CI, and neither has to break anything first.

What the overlap then *costs* is deliberately not asserted: an unlocked race ends in two `stage_satisfied`
events, or a `StaleRequest`, or — with a lucky interleaving — nothing at all. Two consequence examples were
written, passed alone, and failed inside the file; they are gone. The damage is what the three race
descriptions assert does not happen while the lock is there.

**No mocks inside the threads.** rspec-mocks is not thread-safe, so the probes are ordinary subclasses:
`TimedApprove` records its span, `UnlockedApprove` overrides `around_perform` to yield and changes nothing
else.
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

## 8. Questions raised during the build

**None are open.** Q34–Q40 were found by reviewing the merged code against this document on 2026-09-11 and
answered the same day; Q41 was found while checking which of those answers PLAN.md had to carry, and
answered with them. Q11–Q33 were raised during M1a and M1b-1…M1b-10. Every answer is folded into the ticket
it affects.

The seven existed because the last three tickets each met their decision at implementation time instead of
having it collected in advance. Collecting them was the point of the revision; the answers below are what
the remaining five tickets are built on.

### 8.1 Raised by this revision

| ID      | Question                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Bearing on                |
|---------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------|
| **Q34** | **Is there a `Guards::Create`, and does `:may_not_request` survive?** Every guard is `(request:, actor:)` — "may this actor do X to this row". `Create` has no row yet, so it got no guard: `Commands::Create` checks `may_request` inline and raises `NotAuthorized` with a message and **no `reason:`**. Two consequences: `:may_not_request` sits in `Guards::Base::REASONS` unraisable, which M1b-13's locale spec would hit; and M6 has no guard to consult before rendering a "raise a request" button, which is the one thing §7 says a guard is for. | **ANSWER: neither a `Guards::Create` nor dropping the symbol. Raise the symbol now; add a plain predicate when M6 needs one.** `Commands::Create` raises `NotAuthorized.new(request: nil, reason: :may_not_request)` — `Refusal#initialize` already accepts a nil request, so it is a two-word change and the symbol becomes real. `Guards::Base` keeps one signature. The presenter half is **M6a's**, answered by `Operation#requestable_by?(actor)` rather than by a guard: it needs no request, so it is not a guard-shaped question. See M1b-4. | M1b-4 (edit), M1b-13, M6a |
| **Q35** | **Does EvaluateWorkflow's step 0 ship unreachable, or wait for M9b?** In M1 no public call sequence produces the state it handles: at cooldown `0` `Commands::Reject` writes the stage and request rejections in one lock, and under `only_record_rejections` no stage is ever rejected. | **ANSWER: ship it now.** It is correct at every cooldown value and costs one query, and M9b extends the command rather than rewriting it. The branch having no reachable path for a milestone is accepted; its spec drives the stage status directly and says so. | M1b-12 |
| **Q36** | **Who is the actor on `quorum_satisfied` and `stage_satisfied`?** `Commands::Base#emit` stamps `SYSTEM_ACTOR` when `actor` is nil, and EvaluateWorkflow is an internal command with no actor — so a stage closed by a human's approval is attributed to System. | **ANSWER: System is correct.** Closing a stage is the gem's own act, not the approver's; the approvals that caused it are already in the trail, each with its own actor. No actor is threaded through. | M1b-12, M5, M6b |
| **Q37** | **When does the version get bumped, and when does the CHANGELOG get written?** `VERSION` has been `0.2.0` since mid-M1a while `CHANGELOG.md` still ends at 0.1.0. | **ANSWER: neither matters until there are installations.** DoD item 6 is struck. It returns as a real gate at M11, the release milestone. | DoD 6, M11 |
| **Q38** | **What makes a column that no code reads fail CI?** `rejected_at` was missed from the install template and caught by eye rather than by a spec. | **ANSWER: nothing, and that is fine.** No column-list spec. The schema spec keeps asserting indexes and constraints; a column nothing reads is a column nothing breaks, and R3 is cheap while the gem is unreleased. | M1a-2 / M1a-10 |
| **Q39** | **Do `database_cleaner-active_record` and `activejob` stay?** Both are declared and used by nothing. | **ANSWER: both stay.** ActiveJob has users in M3b and M9b; DatabaseCleaner has one in M1b-15, whose specs cannot run inside a transaction. Neither is removed. | M1b-15, M0-1 |
| **Q40** | **What keeps `docs/adr/` and PLAN.md in step?** Nothing enforces the handover from a planned decision to an accepted record. | **ANSWER: out of scope for this plan.** The maintainer keeps them in step by hand. No ticket, no process, and R6 is withdrawn. | process |
| **Q41** | **Which events does `close_stage!` emit?** `Event::KINDS` carried `quorum_satisfied`, `stage_satisfied` **and** `stage_closed`; PLAN.md §7.1 emitted only `stage_satisfied`; this document's M1b-12 emitted two; and **nothing anywhere emitted `stage_closed`** - dead vocabulary of exactly the shape **Q34** removed. | **ANSWER: two events, and `stage_closed` is gone.** `close_stage!` emits one `quorum_satisfied` per quorum that met its threshold, then one `stage_satisfied`. The two answer different questions - a counting rule was met, versus the stage is over - and under `all_quorums` the first happens repeatedly before the second, so the multi-quorum case reads correctly from the same code. At cooldown `0` satisfaction and closing are the same instant, so a third kind would record it twice; **M9b adds `stage_closed`** if the window ever makes the distinction carry information. Applied: PLAN.md §5.5 and §7.1, and `Event::KINDS`. | M1b-12, PLAN §5.5 / §7.1 |

### 8.2 Closed

| ID      | Question                                                                                                                                                                                                      | Answer                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
|---------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Q11** | Does `Create` need a dedupe story now that `idempotency_key` is gone? Two identical submissions produce two pending requests.                                                                                 | **No, and it is not documented.** Rails developers know how to prevent accidental double submission, and a deliberate duplicate is a legitimate request that the approvers can cancel. Neither the README nor PLAN.md explains it.                                                                                                                                                                                                                                      |
| **Q12** | `SYSTEM_ACTOR` used `id "0"`, which a string-keyed host actor could legitimately hold.                                                                                                                        | **Use the non-castable sentinel `"system"`.** §5.5 and §19.15 updated; tickets M1a-7, M1a-9 and M1b-10 follow.                                                                                                                                                                                                                                                                                                                                                          |
| **Q16** | Should the gem constrain `json` for hosts, or keep it a development pin? Raised by M1a-1.                                                                                                                     | **Constrain it.** `spec.add_dependency "json", "~> 2.7"`. A `gemspec` directive in a Gemfile pulls runtime dependencies in too, so this pins the gem's own suite *and* every host - which a development pin never could. See §2 and §19.18.                                                                                                                                                                                                                             |
| **Q13** | Spec-level config isolation: `ChangeRequests.config` is memoised module state, and a mutation in one example is visible in the next - confirmed by probe. `ChangeRequests.operations` adds a second global.   | **A `spec/support` helper that snapshots and restores both**, shipped with M1b-0. Same shape as the two order-dependent failures already hit. **As built** it installs a *copy* per example and restores the originals, which needed `initialize_copy` on both objects - see M1b-0.                                                                                                                                                                                     |
| **Q14** | M1b-0's acceptance required M1b-4's code: a registry can only *describe* a workflow, not materialise one.                                                                                                     | **M1b-0 asserts the description; the materialisation assertion moves to M1b-4.**                                                                                                                                                                                                                                                                                                                                                                                        |
| **Q15** | `ApprovalQuorum` is `Immutable`, so `approval.quorums.destroy_all` raises `ReadOnlyRecord`.                                                                                                                   | **Unapprove deletes the approval and lets the database cascade remove the links.** The obvious code is the wrong code, so M1b-6 says so.                                                                                                                                                                                                                                                                                                                                |
| **Q17** | §9.4 uses `config.actor_identity` for the requester-cannot-approve rule, but only approvals carried an identity column. Raised by M1b-1.                                                                      | **Add `requester_identity` to `change_requests`**, snapshotted by `Commands::Create`. Deferring it would need a second migration for hosts that had already installed. See §5.1 and §9.4.                                                                                                                                                                                                                                                                               |
| **Q18** | M1b-4's acceptance wanted a multi-stage operation, but `op.workflow` is M2.                                                                                                                                   | **Build the `Workflow` description by hand in the spec.** The description objects are public value objects, so the materialiser's multi-stage path is proved now; M2 adds only the DSL that produces such a description.                                                                                                                                                                                                                                                |
| **Q19** | An operation could be declared with no `op.approvals`, producing a request with no stages that could never be approved.                                                                                       | **`Commands::Create` refuses it**, with `ConfigurationError`, alongside a missing `service`. An approval gate with no approvers is a misconfiguration, not a fast path.                                                                                                                                                                                                                                                                                                 |
| **Q20** | §7's `:stage_not_current` branch compares the current stage with itself. What does it actually test?                                                                                                          | **Eligible for a quorum on another stage of this request, but not the current one** — §6.9's stage-three director.                                                                                                                                                                                                                                                                                                                                                      |
| **Q21** | Should `:already_decided` honour `config.actor_identity`?                                                                                                                                                     | **Yes.** §9.4 uses the identity in place of `(type, id)` when counting distinct approvers, and deciding a stage twice is that same question.                                                                                                                                                                                                                                                                                                                            |
| **Q22** | M1b-5 is specified to call `Commands::EvaluateWorkflow`, which is M1b-12.                                                                                                                                     | **The call lands with M1b-12**, together with the advancement specs. M1b-5's own acceptance asks only for the approval, the links and one `approved` event.                                                                                                                                                                                                                                                                                                             |
| **Q23** | Should Unapprove honour `config.actor_identity`, letting one human retract through a second actor class?                                                                                                      | **No.** §9.4 names two uses for the identity and retraction is neither; only the actor who wrote the row may take it back.                                                                                                                                                                                                                                                                                                                                              |
| **Q24** | May Unapprove delete a `rejected` row, or approvals only?                                                                                                                                                     | **Either decision.** Unapprove is "take back my decision on this stage". The default short-circuit makes the request final, so this is reachable through `config.only_record_rejections`.                                                                                                                                                                                                                                                                               |
| **Q25** | Where does Reject's mandatory reason belong, given §7 has the presenter consult the same guard?                                                                                                               | **In the command.** A guard refusing without a reason could never let the button that collects one appear.                                                                                                                                                                                                                                                                                                                                                              |
| **Q26** | Does the default (short-circuiting) rejection branch also write an approvals row, or only the event?                                                                                                          | **Always write the row**, so the table tells one story and the unique index behaves the same either way.                                                                                                                                                                                                                                                                                                                                                                |
| **Q50** | "Each spec fails when `with_lock` is removed" is only probabilistically true — without the lock the damaging interleaving is likely, not certain, so such a spec can pass by luck and redden CI at random. | **Measure the serialisation instead.** Assert no two command bodies overlap with the lock, and that they always do without it. Deterministic in both directions, and it demonstrates the mechanism rather than a downstream symptom. |
| **Q48** | The cross-guard table found a live split: `Approve`/`Unapprove`/`Reject` answered `:not_pending` for a finished request, `Cancel`/`Execute`/`Expire` answered `:already_finalized`. | **Align on `:already_finalized`.** One reason, one class, whichever guard met it — which is what Q29 made the mapping mean. `:not_pending` now covers `approved`/`executing`/`failed` only. |
| **Q49** | §15.2 asks for guard × status × actor role, but the per-guard specs already cover roles.          | **Status × guard declared literally; roles as cross-guard rules.** Each rule states an invariant two guards must share, rather than repeating per-guard work. |
| **Q45** | `Commands::Create` raised `NotAuthorized` with a developer-facing message naming `t.may_request`, and no reason — so `:may_not_request` had no raiser. | **Drop the message, set the reason.** The translation words it for the person being refused; a configuration key has no business in a flash. |
| **Q46** | The ticket said the engine has to add `config/locales` to `I18n.load_path`.                                                    | **It does not.** `Rails::Engine` already does, verified by probe. The directory existing is the whole change — plus `git add`, since the gemspec's file list is `git ls-files`. |
| **Q47** | Shipping real messages made three spec files order-dependent: `I18n.load_path` is process-wide, so "the message is the symbol" held only until some other file booted Rails. | **Assert the fallback with reasons nothing translates.** Deterministic under any seed and any subset of the suite. |
| **Q42** | M1b-11's branch list defined `:not_approved` so broadly that `:attempts_exhausted` was unreachable, contradicting its own rationale. | **Follow the rationale.** `:not_approved` is the status question; `:attempts_exhausted` the ceiling question. Both reachable. |
| **Q43** | `t.may_execute` existed with no reader, so a class declared unable to execute would pass `Guards::Execute`. | **Enforce it in the guard**, with `:not_permitted`, before the separation-of-duties branches. |
| **Q44** | Evaluation was specified for `any_quorum` only, but `satisfied_by: "all_quorums"` is already a valid column value and M1b-4 materialises such stages. | **Implement the satisfaction rule now.** One line beside the `any_quorum` branch; M9a still owns the one-quorum-per-approval *linking* rule. Without it an `all_quorums` stage would close on its first satisfied quorum — "1 Admin AND 2 Owners" met by the Admin alone. |
| **Q32** | Expire's refusals mix an authorization answer (`:not_system`) with state answers, but `refuses_with` names one class and there is no `NotExpirable`.                                                          | **`NotAuthorized` for all of them**, plus the shared `:already_finalized` mapping. Expire is internal; its guard is a floor beneath M3b's query, not a flash.                                                                                                                                                                                                                                                                                                           |
| **Q33** | §7.2 permits Expire when `pending` **or** `approved`, so `:not_pending` would misname the refusal for `executing` and `failed`.                                                                               | **Add `:not_expirable`** to the shared vocabulary.                                                                                                                                                                                                                                                                                                                                                                                                                      |
| **Q30** | §7.2 says Comment is permitted "always" and never calls its body mandatory. Blank body — refuse or record?                                                                                                    | **Refuse**, with `:body_required`. An empty comment is permanent noise in an append-only trail.                                                                                                                                                                                                                                                                                                                                                                         |
| **Q31** | `Guards::Base#check!` passes `request:`/`reason:` to the declared error class, but `NotAuthorized` was a plain `Error` and silently swallowed both. Found by M1b-9, the first guard to declare it.            | **Extract `Refusal` from `TransitionError` and include it in `NotAuthorized` too.** Ancestry untouched; Create's message-only `fail NotAuthorized, "…"` still works.                                                                                                                                                                                                                                                                                                    |
| **Q28** | §7.2 permits Cancel in any non-final status, which includes `executing` — where the target is actually running.                                                                                               | **Refuse while `executing`.** A status change cannot recall it, and a terminal status would leave the execution unable to record its outcome. Narrower than §7.2's wording, recorded there.                                                                                                                                                                                                                                                                             |
| **Q29** | The acceptance wants `AlreadyFinalized`, but `refuses_with` names one error class per guard.                                                                                                                  | **`Guards::Base` maps `:already_finalized` to `AlreadyFinalized`** for every guard; everything else raises the declared class.                                                                                                                                                                                                                                                                                                                                          |
| **Q27** | A mistaken approval is retractable; a mistaken rejection killed the request outright, and `only_record_rejections` — whose purpose is to *not* stop anything — was the only mode where taking it back worked. | **Extend `op.cooldown` to rejection in M9b.** A rejection stops the stage at once and finalises the request only after the window, so `Unapprove` has something to undo. A stage with a standing rejection can never be satisfied; withdrawing the last one returns it to `pending`. At cooldown `0` nothing about M1 changes. See §5.2, §7.1, §7.2 and §19.20. **Consequence found later:** at cooldown `0` the state this describes is unreachable, which is **Q35**. |

---

## 9. Issues found in PLAN.md — all resolved

One needs re-reading against the code: **I10**. The evaluator is `Commands::EvaluateWorkflow` as decided,
but `ChangeRequests::Workflow` came back as the *declaration description* (**Q18**), so a `workflow.rb` does
exist in the §2 layout again — holding value objects, not logic. See M1b-0's **As built**.

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

| ID     | Risk                                                                                                                | Position                                                                                                                                                                                                                                          |
|--------|---------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **R1** | Ruby 4.0.6 + Rails 8.1 compatibility is unverified.                                                                 | **Closed.** Verified by M0-1: both resolve, boot and run the suite. The Rails floor was raised from `>= 7.1` to `>= 8.1` at the same time, matching §18's cut line.                                                                               |
| **R2** | The nine-table migration is written before the install generator exists (M7).                                       | **Closed, inverted as planned:** M1a-2 *is* the generator template, run in specs by `spec/support/gem_schema.rb`, and the headless probe installs from it end to end. M7 inherits a tested artefact.                                              |
| **R3** | Schema mistakes become host migrations after 0.2.0.                                                                 | **Still live, and it has already fired once.** `rejected_at` was missed and back-filled in #34 while the gem is unreleased, which cost one PR. The same miss after 0.2.0 is a migration in every host. See **Q38**.                               |
| **R4** | Guard/inbox predicate drift between M1b-2's Ruby and M9c's SQL.                                                     | **Accepted.** Everything ships together at 1.0; the predicate has one caller (`Guards::Base#qualifying`) and one shared table (`spec/support/eligibility_examples.rb`), so M9c has a single subject to add SQL beside.                            |
| **R5** | The ticket sum is roughly twice §17's original M1 budget.                                                           | **Accepted, and holding.** 29 of 34 tickets merged in three calendar days against 19.25 estimated days — the estimates are wall-clock days for one developer and were never a schedule. §17 carries the same numbers, so the two documents agree. |
| **R6** | ~~The ADR set and PLAN.md record the same decisions at different times, with nothing enforcing the handover.~~ | **Withdrawn (Q40).** The maintainer keeps the two in step by hand. Not a risk this plan carries, and no ticket owns it. |

---

## 11. Estimates

| Block                              | Tickets        | Estimated   | State                                                               |
|------------------------------------|----------------|-------------|---------------------------------------------------------------------|
| M0 prerequisites                   | M0-1 … M0-8    | 5.0         | ✅ merged (+ 4 unplanned items, §2.1)                                |
| M1a — schema and models            | M1a-1 … M1a-10 | 7.25        | ✅ merged (+ `rejected_at` back-fill, #34)                           |
| M1b — operations, guards, commands | M1b-0 … M1b-10 | 7.0         | ✅ merged                                                            |
| **Delivered**                      | **29 tickets** | **19.25 d** | PRs #1–#36, `rake ci` green                                         |
| M1b-11 `Guards::Execute`           |                | 0.5         | ⬜                                                                   |
| M1b-12 `EvaluateWorkflow`          |                | **1.5**     | ⬜ raised from 1.25 — it edits three merged commands                 |
| M1b-13 reason vocabulary and i18n  |                | 0.5         | ⬜                                                                   |
| M1b-14 truth tables and headless   |                | **0.75**    | ⬜ lowered from 1.0 — the per-guard tables landed with their tickets |
| M1b-15 concurrency specs           |                | 0.75        | ⬜                                                                   |
| **Remaining**                      | **5 tickets**  | **4.0 d**   |                                                                     |
| **Total to 0.2.0**                 | **34 tickets** | **23.25 d** | unchanged: the two revisions cancel                                 |

The largest single line is still M1a-2 (2 d), and it earned it: the migration template is the artefact
everything else in the gem is built on, and the one place where being wrong is expensive after the first
adopter — which **R3** demonstrated at the cost of one PR while it is still cheap.

**M1b-12 is the critical path.** M1b-14 cannot finish without it (the headless spec has to reach `approved`),
M1b-15's first and third races cannot be written without it, and DoD items 4 and 5 — the only two of the
five still open — both turn on it. M1b-11 and M1b-13 are the only tickets that can proceed in parallel with
it, and M1b-13 wants two things finished first: M1b-11's `:not_approved` and `:attempts_exhausted`, and
M1b-4's `:may_not_request` amendment (**Q34**), which is small enough to fold into whichever ticket reaches
it. The order is **M1b-11 → M1b-12 → M1b-13 → M1b-14 → M1b-15**, with M1b-11 and M1b-12 independent enough
to swap.

**Nothing is waiting on a decision.** Q34–Q41 were answered on 2026-09-11 and are folded into the tickets
above: M1b-4 gains a two-word amendment (**Q34**), M1b-12 ships step 0 and keeps System attribution
(**Q35**, **Q36**), M1b-15 is DatabaseCleaner's first user (**Q39**), and DoD item 6, a column-list spec and
the ADR handover are all struck (**Q37**, **Q38**, **Q40**). Two answers reached PLAN.md rather than staying
here — **Q34**'s §7.2 footnote and **Q36**'s §5.5 widening — and **Q41** took `stage_closed` out of
`Event::KINDS`, the only code change this revision produced. The one deferred item is
`Operation#requestable_by?`, recorded against **M6a** rather than built here.
