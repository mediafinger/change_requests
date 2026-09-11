# ADR-0011: Attribute gem-originated actions to a System sentinel actor

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

Some transitions have no human behind them: a request expiring, a reaper closing out an
interrupted execution, a cleanup task cancelling requests whose operation was removed. The audit
trail still has to say who did it.

Leaving the actor columns NULL makes every reader handle a null case, and makes "nobody" and "we
forgot to record it" indistinguishable.

## Decision

`ChangeRequests::SYSTEM_ACTOR` is a frozen triple, `{ type: "System", id: "system", label:
"System" }`, written into the actor columns like any other actor
([ADR-0003](0003-actor-references-as-triples.md)). Columns that may carry it opt in explicitly;
`System` is otherwise not an acceptable actor type.

The id is the non-castable string `"system"`, not `"0"`. Actor ids share a string column with host
classes that may legitimately have string primary keys, and `"0"` is a value one of them could hold.

## Consequences

### Positive

- Every event has an actor, and readers need no null branch.
- `System` never appears in `config.actor_types`, so it cannot be mistaken for a registered class,
  and no host record can collide with its id.

### Negative

- A host whose own actor class is literally named `System` cannot register it.
- The sentinel is a magic value, and the columns that accept it have to say so one by one.
