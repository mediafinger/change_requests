# ADR-0018: Express eligibility as data, with one implementation of the predicate

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

"Who may approve this?" has to be answered in three places that must never disagree: the guard, for
one loaded request; the inbox query, for every request awaiting a given actor; and the host's own
policy, where it has one. Expressing eligibility as a block or a lambda answers the first and makes
the second impossible — a predicate in Ruby cannot be paginated.

Hosts also differ in shape. Some have one `User` class and roles; some have `User`, `Admin` and
`Manager` with different key types and unrelated permission models. A gem that assumes either one is
useless to the other.

## Decision

Eligibility is rows, not code. A quorum carries **permission rows** (`permission` × `actor_type`,
each independently nullable) and **named-actor rows**, and the two are OR-ed
([ADR-0008](0008-staged-multi-quorum-schema.md)).

| `actor_type` | `permission` | Means                                   |
|--------------|--------------|-----------------------------------------|
| `User`       | `editor`     | Users holding `editor`                  |
| `NULL`       | `editor`     | anyone holding `editor`                 |
| `Admin`      | `NULL`       | any Admin, whatever their permissions   |
| `NULL`       | `NULL`       | rejected — constraining nothing is a bug |

`permission_match` sits on the **quorum**, not in global configuration: the same rows mean "any of
these" under `any` and "this actor holds every one of them" under `all`. Identical data, opposite
meanings, so the mode belongs beside the rows it governs. Configuration supplies only the default.

An actor's permissions are read through **their registered type's lambda**, never through a method on
the actor, so `User` and `Admin` may derive them completely differently and still be compared against
one quorum definition.

`Authorization::Permissions#allows?(actor:, quorum:)` is the one implementation of the predicate, and
`Guards::Base#qualifying` is its one caller. A host replaces it wholesale by assigning
`config.authorization`; a bare `->(actor:, request:, stage:, action:)` is coerced into
`Authorization::Callable` on assignment, so the host writes a lambda and the gem still has an object
answering `allows?`.

## Consequences

### Positive

- The inbox becomes one indexed, paginated query over the same rows the guard reads, rather than a
  scan through Ruby.
- Heterogeneous actor classes are a first-class case, not a workaround
  ([ADR-0003](0003-actor-references-as-triples.md)).
- Because the rows are materialised per request and immutable, editing an operation's permission
  list never changes who may approve something already in flight.

### Negative

- Four joins to answer "may this person approve?", where a lambda would have been one call.
- A quorum with no permission rows grants eligibility to nobody by permission — "all of nothing" has
  to be special-cased, or a named-approver quorum would admit everyone under `permission_match: all`.
- When the inbox query ships, its SQL and this Ruby predicate become two expressions of one rule. The
  mitigation is that there is exactly one Ruby implementation and one shared table of cases for the
  SQL to be held against, not that the risk is absent.
- An unregistered actor class raises rather than returning false. That is the allowlist working, but
  it means the predicate is not total over arbitrary objects.
