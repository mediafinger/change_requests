# ADR-0021: Serialise commands with a row lock and let the unique index arbitrate

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

Approvals arrive from people, which means they arrive at the same moment often enough to matter. Two
races are real in an approval workflow and neither is exotic: two approvers racing the last slot of a
quorum, and one approver double-clicking.

The first must transition the stage exactly once. The second must be refused the way the guard would
have refused it — a duplicate submission is a user error, and answering it with an exception page
turns a mis-click into an incident.

## Decision

Every command body runs inside `request.with_lock`
([ADR-0016](0016-commands-are-the-only-writers.md)), so no two transitions on one request are ever in
flight together. The lock is taken on the request rather than on the stage: a transition reads the
stage, its quorums and their links, and decides the request's own status from them.

**The lock is not the guarantee, the unique index is.** `(change_request_stage_id, approver_type,
approver_id)` is what makes one decision per person per stage true even against a caller that never
took a lock. The lock narrows the window; the constraint closes it. `on_conflict` is what turns the
database's answer back into the gem's, so the loser hears `NotApprovable(:already_decided)`.

The regression specs run real threads on real connections against real PostgreSQL, outside the
suite's transaction — a second connection cannot see uncommitted rows, so these examples truncate
instead.

**The specs measure serialisation rather than removing the lock.** "Assert the race breaks without
`with_lock`" is only probabilistically true: the damaging interleaving is likely, not certain, so such
a spec passes by luck and reddens CI at random. Instead both probes measure the thing the lock exists
to control — were two command bodies ever inside at the same time? With the lock, never; with it
removed and the body held open, always. Both directions are deterministic. What the overlap then
*costs* is deliberately not asserted, because that does depend on the scheduler.

## Consequences

### Positive

- Exactly one of two racing approvals closes the stage, and the stage-closing events are written
  once rather than once per thread.
- A lost race is a domain refusal with a reason, never a `RecordNotUnique` reaching the host.
- The teeth of the concurrency specs are a measurement that holds under any scheduler, so they can
  run in CI on every commit.

### Negative

- A row lock per transition is a serialisation point on the busiest request, and the lock is held
  across the event insert.
- The concurrency examples cannot use rspec-mocks, which is not thread-safe; the probes are ordinary
  subclasses of the command, which is more code and must be kept in step with it.
- These examples opt out of transactional fixtures and clean up by truncation, so they are the one
  group in the suite whose isolation is different from every other.
