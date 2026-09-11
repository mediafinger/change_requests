# ADR-0003: Reference host actors by a (type, id, label) triple

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

The gem records who requested, who approved and who executed, but knows nothing about the host's
user model. Hosts have several actor classes at once (`User`, `Admin`, `Accounts::Manager`), key
them with integers, uuids or strings, and delete them. A foreign key into a host table would force
one class, one key type, and would take the audit trail down with the record.

## Decision

Every actor reference is three columns: `*_type`, `*_id` and, where a decision was recorded,
`*_label`.

- `*_id` is a **string** column, so heterogeneous primary key types share it.
- `*_type` is validated against `ChangeRequests.config.actor_types`, a registry the host declares.
  The registry is the allowlist: a stored type string is compared against it and is never
  `constantize`d to decide whether it is acceptable.
- `*_label` is **snapshotted at write time** through the lambda the registration supplies, and is
  never recomputed.

No foreign key in the gem points at a host table, and none ever will.

## Consequences

### Positive

- A request stays readable after the actor record is deleted or renamed.
- A typo in a type string fails at creation, not at render time.
- Hosts mix actor classes and key types freely. A registration also declares the class's `key_type`,
  so a reader can cast the string back to the host's own key.

### Negative

- The stored label is a snapshot and drifts from the record. `config.actor_label_strategy` exists so
  that readers can prefer the live record and fall back to the snapshot.
- Nothing at the database level guarantees an actor still exists; referential integrity here is a
  deliberate non-goal.
- Every actor class must be registered before it can request or approve, which is one more thing a
  host has to remember.
