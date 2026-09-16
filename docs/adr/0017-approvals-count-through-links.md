# ADR-0017: Count approvals only through the links written at decision time

- **Status:** Accepted
- **Date:** 2026-09-12
- **Corrected:** 2026-09-16

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

**Which quorums an approval links to depends on `satisfied_by`.** Under `any_quorum` it links to every
quorum the actor qualifies for: satisfying any one ends the stage. Under `all_quorums` it links to
exactly one, the lowest-`position` pending quorum the actor qualifies for, so one person holding two
roles cannot meet two quorums that must both be met. `Guards::Approve#countable_quorums` computes
the set; `Commands::Approve` writes it ([ADR-0015](0015-one-guard-object-per-transition.md)).

`ChangeRequests::Commands::EvaluateWorkflow` is the only code that changes stage or request status as
a consequence of a decision. It is a command like any other
([ADR-0016](0016-commands-are-the-only-writers.md)) but internal: no actor, never called by a host,
invoked only from `Approve`, `Unapprove` and `Reject` inside the lock they already hold. It runs in
order:

0. A rejection standing on the current stage makes it `rejected`, whatever its approvals say; a stage
   that was rejected and holds none any more returns to `pending`, with its approvals still counting.
1. Recount every quorum of the current stage from its links, setting or clearing `satisfied_at`, and
   emit `quorum_satisfied` for each quorum that became satisfied.
2. The stage is satisfied when **any** of its quorums is, or **all**, per `satisfied_by`.
3. A satisfied stage closes immediately, and the request advances to the next stage — or becomes
   `approved` when none remains.

`quorum_satisfied` is emitted when the quorum is met, and closing emits one `stage_satisfied`, both
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

- Under `all_quorums` the order of quorums is load-bearing: an actor qualifying for two lands on the
  lower `position`, and a host that wanted them counted toward the other has to reorder the
  declaration.
- A quorum can be demoted by `Commands::Unapprove`, and that emits no event of its own. The
  withdrawn decision's `unapproved` event already names the quorums it counted toward, so a trail
  reader reconstructs the demotion from that row rather than from a dedicated kind.
- Reopening a rejected stage does not clear `rejected_at`. Nothing writes that column yet, so there
  is nothing stale to clear; the milestone that starts writing it has to clear it here.
- `Stage`'s `satisfied` status and `satisfied_at` are unreachable while every cooldown is zero: a
  satisfied stage closes in the same breath. They exist for the window that has not shipped.
