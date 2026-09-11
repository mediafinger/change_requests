# ADR-0017: Count approvals only through the links written at decision time

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

"Is this stage satisfied?" can be answered two ways. Either re-evaluate every approver against every
quorum whenever something changes, or record at decision time which quorums an approval counted
toward and count those rows afterwards.

Re-derivation has a failure mode that is easy to miss and impossible to explain afterwards: an
approver's permissions change, the re-evaluation no longer matches them to the quorum they approved,
and a request that was approved quietly is not any more. Nobody did anything, and the audit trail
shows nothing, because nothing happened.

## Decision

`change_request_approval_quorums` records which quorums an approval counted toward, written by the
command at decision time and **never re-derived**
([ADR-0007](0007-append-only-audit-trail.md) makes the rows immutable). A quorum is satisfied when
its linked approvals reach its `threshold`, and that count is the only rule.

`ChangeRequests::Commands::EvaluateWorkflow` is the only code that changes stage or request status as
a consequence of a decision. It is a command like any other
([ADR-0016](0016-commands-are-the-only-writers.md)) but internal: no actor, never called by a host,
invoked only from `Approve`, `Unapprove` and `Reject` inside the lock they already hold. It runs in
order:

0. A rejection standing on the current stage makes it `rejected`, whatever its approvals say; a stage
   that was rejected and holds none any more returns to `pending`, with its approvals still counting.
1. Recount every quorum of the current stage from its links, setting or clearing `satisfied_at`.
2. The stage is satisfied when **any** of its quorums is, or **all**, per `satisfied_by`.
3. A satisfied stage closes immediately, and the request advances to the next stage — or becomes
   `approved` when none remains.

Closing emits one `quorum_satisfied` per satisfied quorum and then one `stage_satisfied`, both
attributed to the System sentinel ([ADR-0011](0011-system-sentinel-actor.md)). Closing a stage is the
gem's own act, not the approver's: the approvals that caused it are already in the trail one row
earlier, each naming the person who gave it, and attributing the close to whoever approved last would
assert a decision that person never made.

**Closed stages are immutable and there is no rollback into an earlier one.** A stage's outcome, once
closed, is a historical fact. Rejection is a stop rather than a count: one rejection from an eligible
approver or from the requester stops the stage, and no rejection threshold is modelled.

## Consequences

### Positive

- A later role change cannot silently un-approve a request. The links say what was true when the
  decision was made, which is the only moment at which it was a decision.
- Counting is a `GROUP BY` over an indexed table rather than a re-evaluation of every approver
  against every quorum.
- Step 0 is correct at every cooldown value, so the window that a later milestone puts between
  stopping a stage and finalising the request extends this command instead of rewriting it.

### Negative

- **The `all_quorums` linking rule is not implemented yet.** Under `any_quorum` an approval links to
  every quorum the actor qualifies for, which is right, because satisfying any one of them ends the
  stage. Under `all_quorums` it should link to exactly one — the lowest-`position` quorum the actor
  qualifies for — so that one person holding two roles cannot close two quorums that must both be
  met. It currently links to all of them, so an actor holding both `admin` and `owner` satisfies
  "one Admin **and** one Owner" alone. The stage-satisfaction half of `all_quorums` ships and is
  correct; only the linking half is outstanding. No shipped declaration syntax can build such a
  stage — `op.approvals` describes one stage holding one quorum — so nothing reaches it today, and
  it must be closed before the workflow DSL makes multi-quorum stages declarable.
- **`quorum_satisfied` is emitted when the stage closes, not when the quorum was met.** For a
  single-quorum stage the two moments are the same. Under `all_quorums` they are not: a quorum met by
  an earlier approval gets its event later, timestamped at the close, and a quorum on a stage that
  never closes gets none at all. The trail never claims a satisfaction that was later withdrawn,
  which is the compensation, but it does not yet answer "when was this counting rule met".
- Reopening a rejected stage does not clear `rejected_at`. Nothing writes that column yet, so there
  is nothing stale to clear; the milestone that starts writing it has to clear it here.
- `Stage`'s `satisfied` status and `satisfied_at` are unreachable while every cooldown is zero: a
  satisfied stage closes in the same breath. They exist for the window that has not shipped.
