# ADR-0016: Make commands the only writers, under one lock and one event path

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

A request's state lives in several rows: the request, its current stage, its quorums, an approval and
its quorum links, and an event. A transition touches most of them. If callers assemble those writes
themselves, every call site is a chance to write four of the five, and the audit trail is the first
thing to be forgotten because it is the only one nothing else depends on.

Concurrency makes the same point sharper. Two approvals arriving together must not both believe they
were the last one needed.

## Decision

One command class per transition, under `lib/change_requests/commands/`. `Commands::Base.call`
resolves the guard, performs the writes and emits the event, and **wraps the whole body in
`request.with_lock`** — `SELECT … FOR UPDATE`, which also reloads, so a command reads the row it
locked rather than the object it was handed.

- **Commands raise.** There is no result object and no `success?`. A refusal is an exception carrying
  a reason ([ADR-0012](0012-declared-error-taxonomy.md)), because the caller that ignores a returned
  failure is the caller that writes the bug.
- **Commands never accept permissions from the caller.** They take an actor; the gem resolves that
  actor's permissions through the registry ([ADR-0018](0018-eligibility-is-data.md)). A
  caller-supplied permission set is unverifiable by the gem and untestable by the host.
- **`emit` is the single write path for events.** It stamps the actor triple (or the System
  sentinel, [ADR-0011](0011-system-sentinel-actor.md)), `occurred_at`, and the `operation_version`
  read live from the declaration — deliberately not the request's creation-time value, which the row
  already holds. The rule is enforced by a spec that scans `lib/` and fails if any other file writes
  an event.
- **Lost races surface as domain refusals.** `on_conflict` declares which `TransitionError` an
  `ActiveRecord::RecordNotUnique` becomes, so the loser of a duplicate-decision race is told
  `:already_decided` rather than getting a 500. An unmapped conflict is re-raised: that is a bug to
  see, not a refusal to dress it up as.
- `ActiveRecord::StaleObjectError` maps to `StaleRequest`. `lock_version` is the belt to
  `with_lock`'s braces.

**A distinct intent gets a distinct command class, never a flag.** Every command hard-codes the event
kind it emits, so a caller-supplied kind would be the first exception to that. `Commands::Override`
is `Execute` with `override: true`; `Commands::CancelUndeclared` is `Cancel` emitting
`operation_undeclared` instead of `canceled`. Both are **subclasses**, not delegations, so the rows
and events they write cannot drift from the command they wrap — there is nothing there to drift.
`Cancel` carries exactly two seams for it, the event kind and the metadata, and nothing else.

Three commands depart from the locking shape, each for a stated reason:

- `Commands::Create` has no row to lock until it has written one, so it wraps a transaction instead
  — the request and its whole stage, quorum, permission and eligible-actor graph are all-or-nothing.
- `Commands::EvaluateWorkflow` ([ADR-0017](0017-approvals-count-through-links.md)) takes no lock of
  its own: it is internal, invoked only from inside a caller that already holds one, and re-locking
  would reload the row that caller has just written to.
- `Commands::Execute` takes none either, for the opposite reason to Create's: §8 forbids holding a
  lock across the target invocation, and the three transactions it drives each take their own
  ([ADR-0022](0022-execution-in-three-transactions.md)).

`Commands::SettleExecution` is the one command that does not stamp the acting actor on its event. It
takes no actor at all: the executer's triple was recorded on the attempt when the claim was made, and
it reads that back — which is what lets a background job settle a claim it never made, and makes the
`executed` event name whoever actually claimed the run.

## Consequences

### Positive

- Every state change goes through one place per transition, so the event, the status and the rows
  cannot drift apart.
- Two command bodies are never inside the same request at once; that is asserted by measuring
  overlap on real threads rather than by removing the lock and hoping the scheduler cooperates
  ([ADR-0021](0021-serialise-commands-let-the-index-arbitrate.md)).
- A host rescues `ChangeRequests::Error` once and gets a flash instead of an exception page.

### Negative

- Every transition holds a row lock for the duration of its writes, including the event insert.
- The `emit` invariant is enforced by scanning source text. It is stronger than a runtime assertion
  — it catches a path no spec exercises — but it is a regular expression over the tree, and a
  sufficiently creative write would slip past it.
- Commands return the request, except `Comment`, which returns the event it wrote, because the
  request is unchanged by it, and `Commands::ClaimExecution`, which returns the attempt its
  successor has to finish.
- "Commands are the only writers" is now enforced across more classes than a reader expects:
  `ClaimExecution`, `SettleExecution` and `Reap` are commands nobody calls directly, existing only
  so that a sweep or a runner has something to write through. The alternative was a second event
  path, which is the rule this record exists to keep.
