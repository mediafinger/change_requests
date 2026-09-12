# Findings: Functional Capabilities & Missing Features After Milestone 3b

**Document Version:** 2.0  
**Analysis Date:** 2026-09-12  
**Target Milestone:** Milestone 3b (Release `v0.4.0`) — **Fully Implemented**  
**Context:** Milestones M0, M1a, M1b, M2, M3a, and M3b are now completely implemented and merged into `main` (`v0.4.0`). ADRs 0022 through 0028 document the architecture decisions established during M2 and M3.

---

## Executive Summary

**Can you release this as a functional gem that allows forming an approval process after M3b?**

* **Yes, as a Headless Domain Core (v0.4.0)**: A host application can declare operations, create change requests, process multi-stage approval/rejection workflows with separation of duties, execute approved actions (inline or asynchronously via ActiveJob) with double-execution protection, retry failed targets, override policies via break-glass paths, and sweep stale/stuck requests via rake tasks. All of this works programmatically via the Ruby API (`ChangeRequests.request!`, `ChangeRequests::Commands::*`).
* **No, if expecting a complete Rails Engine with UI and out-of-the-box installation**: At the end of Milestone 3b, there is **no Web UI** (no controllers, routes, or views), **no install generator** (the migration template exists but must be manually installed), **no presenters or JSON API serializer**, **no approver inbox query** (`awaiting_approval_from`), **no automated notifications** (`on_event`), and **no host test kit** (`rspec` helpers). Furthermore, `all_quorums` stages carry a known multi-role linking gap until Milestone 9a.

In short: after Milestone 3b, the gem is a **rock-solid, concurrency-safe, headless approval engine**. You can release it as a `0.4.0` developer/headless release, provided the host is prepared to write their own UI/API controllers and manually copy the database migration.

---

## 1. What Is Functional After Milestone 3b

Upon completing Milestone 3b (tickets `M3a-1` through `M3a-5` and `M3b-1` through `M3b-3`), the gem delivers the following complete feature set:

### 1.1 Complete Headless Domain Core & Schema (M0, M1a)
* **PostgreSQL Schema**: All nine tables migrated with UUID primary keys and foreign keys:
  * `change_requests`, `change_request_stages`, `change_request_quorums`, `change_request_quorum_permissions`, `change_request_quorum_eligible_actors`, `change_request_approvals`, `change_request_approval_quorums`, `change_request_events`, `change_request_attempts`.
* **Data Integrity**: Database-level CHECK constraints, terminal-state immutability (`successful`, `rejected`, `canceled`, `expired`), and append-only event logs.
* **Polymorphic Heterogeneous Actors**: Actor references stored as `(type, id, label)` triples with zero foreign keys to host tables, allowing multiple actor classes (`User`, `Admin`, etc.) with UUID, integer, or string keys.
* **Immutable Snapshotting**: Requester labels, actor labels, sparse `payload_labels`, and creation-time `operation_version` survive deletion of host records.

### 1.2 Operation Registry & Workflow DSL (M1b, M2)
* **Operation Definition**: Declared in initializers via `ChangeRequests.operations.define "operation.key" do |op|`.
* **Full Workflow DSL (`op.workflow`, ADR-0023)**:
  * Single canonical way to declare workflows (legacy shorthand `op.approvals` removed).
  * Sequential stages (`w.stage :name, satisfied_by: :any_quorum | :all_quorums`).
  * Flexible quorum counting rules (`q.quorum :name, permissions:, actor_type:, eligible_actors:, match: :any | :all, threshold:`).
  * Single-quorum stage shorthands with `threshold:` keyword.
* **Verification & Target Contract (ADR-0024, ADR-0025)**:
  * `Operations#verify!` and `rake change_requests:verify` validate all declarations at boot and in CI.
  * Engine `to_prepare` reloader hook checks declarations on reload in development.
  * `Execution::TargetContract` enforces that targets are public singleton methods (`def self.call`), accept keyword arguments only, and declare idempotence.

### 1.3 Request Lifecycle & Commands (M1b, M2, ADR-0016, ADR-0026)
* **Host Entry Point**: `ChangeRequests.request!(key, payload:, requester:, tenant: nil)` to record intent and materialize stages/quorums.
* **Guarded Command Suite**:
  * `Commands::Approve`: Records decision, links quorum, advances workflow.
  * `Commands::Unapprove`: Withdraws an approval, demoting the stage/request if a quorum is lost.
  * `Commands::Reject`: Rejects the stage/request with a mandatory reason.
  * `Commands::Cancel`: Cancels in-flight requests (with a mandatory reason; open to anyone if the operation is undeclared).
  * `Commands::CancelUndeclared < Cancel`: System command emitting `operation_undeclared` when an operation declaration vanished.
  * `Commands::Comment`: Free-text post-mortem or in-flight notes.
* **Guard Rules & Separation of Duties**:
  * Requesters can **never** approve their own requests (enforced by identity).
  * Configurable execution rights (`config.requester_may_execute`, `config.approver_may_execute`).
  * Closed refusal vocabulary (`NotApprovable`, `NotExecutable`, etc.) with i18n support.
* **Workflow Advance (`Commands::EvaluateWorkflow`)**:
  * Sequential stage progression (`current_stage_position + 1`).
  * Automatic transitions to `approved` once all stages meet criteria, or `rejected` upon rejection.

### 1.4 Execution Engine & Safety (M3a, ADR-0022, ADR-0024)
* **Claim-then-Invoke Pattern (T1/T2/T3 split)**:
  * **T1 (with lock via `Commands::ClaimExecution`)**: Conditional `UPDATE` claiming status `executing`, creates attempt record, commits transaction.
  * **T2 (without lock)**: Dispatches to the target service (`Dispatcher.call`). Holds no row locks across network or heavy I/O.
  * **T3 (with lock via `Commands::SettleExecution`)**: Records outcome (`successful` or `failed`), finished timestamp, and updates attempt record. Failures leave a durable record outside any rolled-back transaction.
* **Double-Execution Prevention**: Guaranteed by conditional `UPDATE` and unique index on `(change_request_id, number)`. Concurrent claims raise `ExecutionInProgress`.
* **Idempotency & Retries**: Passes `change_request_id:` to targets declaring the keyword; enforces retry ceiling (`max_attempts`).
* **Break-Glass Override (`Commands::Override < Execute`, ADR-0026)**:
  * `Commands::Override.call(request:, actor:, reason:)` executes unapproved requests under `op.override` policy.
  * Emits `overridden` event recording the shortfall at claim time; marks `overridden_at`.

### 1.5 Background Execution & Scheduled Maintenance (M3b, ADR-0027, ADR-0028)
* **Asynchronous Execution**: `config.execution_mode = :background` dispatches T2/T3 to `ChangeRequests::Execution::Job` (ActiveJob optional dependency).
* **Maintenance Sweepers (`ChangeRequests::Maintenance`)**:
  * `expire_stale!`: Transitions expired pending/approved requests to `expired`.
  * `reap_stuck_executions!(older_than:)`: Reaps abandoned in-flight executions older than 1 hour to `failed` (`outcome: abandoned`) via `Commands::Reap` and `Guards::Reap`. Exempt from undeclared operation refusal (PLAN.md §5.11, Decision 14).
  * `cancel_undeclared!`: Bulk-cancels non-final requests whose operations have been removed from code.
* **Rake Tasks & Scheduling**:
  * Cron-ready tasks: `change_requests:expire_stale` and `change_requests:reap_stuck_executions`.
  * `change_requests:cancel_undeclared` is deliberately **kept off cron** (manual/operator only) to prevent accidental mass cancellation if an initializer fails to load during deploy.

---

## 2. What Features Will Be Missing After Milestone 3b

Releasing after Milestone 3b leaves the following components and milestones unbuilt:

| Area                           | Milestone         | Missing Feature                                                                           | Impact on Adopter                                                                                                                |
|--------------------------------|-------------------|-------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| **Packaging & Installation**   | **M7**            | `rails g change_requests:install` and code generators                                     | Adopters cannot run a generator to install migrations or initializers. Must manually copy `migration.rb.tt` into `db/migrate/`.  |
| **Web UI**                     | **M6a, M6b, M6c** | Rails Engine UI (`RequestsController`, views, partials, routes, CSS, Turbo)               | Mounting `ChangeRequests::Engine` provides no web interface. Adopters must build their own approval dashboards and screens.      |
| **Presenters & Serialization** | **M5**            | `RequestPresenter`, `CollectionPresenter`, Value Objects, `as_json`                       | No view models or JSON API contract out of the box. Adopters must query raw ActiveRecord models directly.                        |
| **Approver Inbox Query**       | **M9c**           | `Request.awaiting_approval_from(actor)`                                                   | Adopters cannot easily query "which requests need my approval?" with a single indexed SQL scope; they must write custom queries. |
| **Multi-Quorum Linking**       | **M9a**           | Lowest-position quorum linking under `all_quorums`                                        | **Correctness Gap**: An actor holding multiple roles satisfies multiple quorums with one approval in `all_quorums` stages.       |
| **Cooldown Window**            | **M9b**           | `op.cooldown`, `CloseStageJob`, `close_due_stages!`                                       | Stages cannot stay in a reversible holding window after meeting thresholds; decisions are immediately final.                     |
| **Actor Helpers & Tenancy**    | **M4**            | `ActorRef` value object, batch resolution, `visible_scope`, `ChangeRequests::Actor` mixin | No N+1 prevention for actor live records; no automatic tenant scoping helper; host models lack association helpers.              |
| **Notifications & Hooks**      | **M10**           | `config.on_event` after-commit callback, `ActiveSupport::Notifications`                   | No built-in hooks to trigger Slack/email notifications when requests are submitted, approved, or executed.                       |
| **Host Test Kit**              | **M8**            | `require "change_requests/rspec"`, matchers, sandboxes, shared examples                   | Host test suites have no shared helpers or RSpec matchers (`be_approvable_by`, etc.) to test their own workflows.                |
| **Public Documentation**       | **M11**           | End-user guides, complete README usage, RBS typing                                        | README usage remains a `TODO`; no published adoption guide.                                                                      |

---

## 3. Known Correctness Gaps & Edge Cases at M3b

1. **`all_quorums` Multi-Role Linking Gap (Deferred to M9a)**:
   * *Behavior*: If an operation defines a stage with `satisfied_by: :all_quorums` (e.g., "1 Admin AND 2 Owners"), and an approver holds both roles, their single approval links to both quorums and satisfies both.
   * *Mitigation*: Single-quorum stages (the predominant use case) are completely unaffected and behave correctly. Shape (b) carries a pending spec in the suite (`Plan_M2.md` M2-6) until M9a lands.
2. **`op.cooldown` Belongs to M9b**:
   * Stated in `PLAN.md` §17.1 (closed): `op.cooldown` belongs to M9b along with `CloseStageJob` and `close_due_stages!`. In M3b, all stage decisions act immediately (cooldown 0).
3. **`Operation#requestable_by?(actor)` (Deferred to M6a)**:
   * The predicate for whether an actor may submit a request is evaluated inside `Commands::Create`, but the public query method on `Operation` for UI buttons does not ship until M6a.

---

## 4. Release Verdict & Recommendations

### Can you release v0.4.0?
**Yes, but strictly scoped as a Headless Domain Core.**

If you release at the end of Milestone 3b as `v0.4.0`:
1. **Target Audience**: Backend-driven applications, API-only Rails apps, or teams with custom admin panels (ActiveAdmin, Avo, Administrate, or custom React/Vue frontends) that only need the underlying state machine, approval rules, and execution engine.
2. **Prerequisites for Adopters**:
   * Must manually copy the migration template from `lib/generators/change_requests/install/templates/migration.rb.tt` to `db/migrate/`.
   * Must write their own controllers to invoke `ChangeRequests.request!` and `Commands::*`.
   * Must build their own views or JSON responses from the ActiveRecord models.
   * Must stick to single-quorum stages or be aware of the `all_quorums` multi-role limitation.
3. **Documentation Requirement**:
   * The README's `TODO: Write usage instructions here` must be replaced with the headless walkthrough (configuration, operation definition, `request!`, and command execution).

###  Can you release v0.6.0? (after implementing M4 & M5)

#### **Yes, as a Headless JSON API / Presenter-Driven Release (`v0.6.0`)**
If you implement everything in `Plan_M4.md`, the gem reaches a major milestone where it can be released as a **complete presentation-agnostic approval framework**:
* **Zero N+1 Queries**: `CollectionPresenter` and `ActorResolver` batch-load actors in one query per actor class across arbitrary heterogeneous types (`User`, `Admin`).
* **Complete View Models**: Any host application building an API, a Single Page App (React/Vue), a mobile interface, or custom admin pages (Avo, ActiveAdmin, Administrate) gets fully assembled view models (`RequestPresenter`, `Value::StageProgress`, `Value::Action`) with translated labels and disabled tooltips without writing presentation logic.
* **Versioned `as_json` Contract**: First-class JSON serialization for API-driven architectures.

#### **What Will Still Be Missing for a General Rails Engine Release**
If adopters expect a standard, plug-and-play Rails engine, the following components remain unbuilt:
1. **Web UI (M6a, M6b, M6c)**: No controllers, routes, ERB views, partials, CSS, or Turbo/Stimulus integration. Mounting the engine currently has no routes to mount.
2. **Install Generator (M7)**: `rails g change_requests:install` does not exist. Adopters must manually copy `lib/generators/.../migration.rb.tt` into `db/migrate/`.
3. **Host Test Kit (M8)**: `change_requests/rspec` matchers and sandboxes are not yet available for adopters to test their own actions.
4. **Approver Inbox Query (M9c)**: `Request.awaiting_approval_from(actor)` is not yet built; hosts must write their own queries to list open tasks for a user.
5. **Multi-Quorum Linking Gap (M9a)**: Approvers holding multiple roles still satisfy multiple quorums in `all_quorums` stages (held as a pending tripwire in `shapes_spec.rb`).
6. **Cooldown Holding Window (M9b)**: `op.cooldown` does not exist; approvals/rejections are immediate.
7. **Event Notifications (M10)**: `config.on_event` and `ActiveSupport::Notifications` hooks are not yet dispatched.
