# ADR-0007: Make the audit trail and the eligibility rows append-only

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

`change_request_events` is the record of what happened and who did it. Its value depends entirely on
nobody being able to revise it afterwards.

The eligibility rows — `change_request_quorum_permissions`,
`change_request_quorum_eligible_actors`, `change_request_approval_quorums` — need the same
protection for a different reason. They are materialised from the operation's workflow when the
request is created, and they are the frozen snapshot: editing an operation must never change who may
approve a request already in flight.

## Decision

`Concerns::Immutable` installs `before_update` and `before_destroy` callbacks that both raise
`ActiveRecord::ReadOnlyRecord`. It is included by `Event`, `QuorumPermission`,
`QuorumEligibleActor` and `ApprovalQuorum`.

It raises `ActiveRecord::ReadOnlyRecord`, not a `ChangeRequests::Error`: this is an unsupported
operation, not a refused domain transition ([ADR-0012](0012-declared-error-taxonomy.md)).

`ON DELETE CASCADE` bypasses it, by design — deleting a request takes its whole graph with it.

## Consequences

### Positive

- History cannot be rewritten through the model layer, including by the gem's own commands.
- No `dependent:` option is needed, or wanted, on the associations that point at these rows; the
  database cascade is the only deletion path.

### Negative

- Code that needs such rows gone has to delete a parent and let the cascade do it. Removing an
  approval's quorum links, for instance, means deleting the approval — the obvious
  `approval.quorums.destroy_all` raises.
- Enforcement is application-level. A host that wants it below the application adds `DO INSTEAD
  NOTHING` rules itself; see [docs/08_events_and_notifications.md](../08_events_and_notifications.md).
