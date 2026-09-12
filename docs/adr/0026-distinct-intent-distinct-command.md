# ADR-0026: Give a distinct intent a distinct command class, not a flag

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

Two transitions in the gem are the same mechanics with a different meaning.

Executing with `override: true` does what executing does, on a request that never reached `approved`
— but §8.1 wants the exception to *look* like one, and `Execute.call(…, override: true)` buried in a
controller does not. Cancelling because a declaration vanished writes the same columns an ordinary
cancellation writes, but "nobody decided this, its declaration disappeared" is a different fact from
"someone called it off", and a timeline should not have to infer which from the actor column.

Both could have been a boolean. Both would then have needed a caller-supplied event kind, which no
command in the gem has: every one hard-codes the kind it emits.

## Decision

A distinct intent gets a distinct command class, implemented as a **subclass** of the command it
wraps:

- `Commands::Override < Execute` — `.call(request:, actor:, reason:)`, which is `Execute` with
  `override: true`. It adds a name and nothing else.
- `Commands::CancelUndeclared < Cancel` — emits `operation_undeclared` instead of `canceled`, and
  adds the operation key and the request's creation-time version to the metadata. `Cancel` carries
  exactly two seams for it, the event kind and the metadata, and is otherwise untouched.

Subclassing rather than delegation is deliberate: the rows and events the wrapper writes **cannot**
drift from the command it wraps, because there is nothing in the wrapper to drift. The equivalence is
asserted anyway, by comparing both snapshots.

The same rule decides which event a cancellation emits. **Who cancelled decides**: a person
cancelling a stranded request emits `canceled` with their own reason, because they cancelled it; the
sweeper emits `operation_undeclared`, because nobody did.

## Consequences

### Positive

- M5's presenter renders `:execute` and `:execute_override` as two actions — the second `tone:
  :danger` and always confirmed — without branching on a boolean.
- A timeline records the fact, not the mechanism. Filtering for `operation_undeclared` finds every
  request closed out by a vanished declaration, with no join to the actor column.
- Every command still hard-codes its own event kind, so the "one kind per class" rule holds without
  exception.

### Negative

- Two classes exist that add almost no code, and a reader looking for the override logic finds it in
  `Guards::Execute` and `ClaimExecution` rather than in `Commands::Override`. The name is the point,
  but the name is also all there is.
- `Commands::Cancel` carries two seams it never uses itself, which is a small permanent cost paid so
  a subclass can exist.
- The convention did not extend cleanly to declarations. `op.override` is a declarer whose reader had
  to be named `override_policy`, because — unlike `op.workflow` — it has no block to distinguish
  "declare this" from "tell me what was declared", and a bare `op.override` that read instead of
  declaring would have left the gate shut while looking open.
