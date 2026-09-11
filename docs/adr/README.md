# Architecture Decision Records

One record per significant architectural choice: its context, the decision, and what it costs.

These describe the gem **as it stands today**. Decisions still ahead of the implementation live in
`PLAN.md` until the code that makes them real exists.

A record is never edited once accepted. It is superseded by a later one, which links back to it.

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-headless-domain-core.md) | Keep the domain core headless | Accepted |
| [0002](0002-mountable-engine-with-isolated-namespace.md) | Ship the Rails layer as a mountable engine with an isolated namespace | Accepted |
| [0003](0003-actor-references-as-triples.md) | Reference host actors by a (type, id, label) triple | Accepted |
| [0004](0004-uuid-primary-keys.md) | Use uuid primary keys for every gem-owned table | Accepted |
| [0005](0005-string-states-with-check-constraints.md) | Store states as strings with CHECK constraints, not PostgreSQL enums | Accepted |
| [0006](0006-creation-time-immutability.md) | Enforce creation-time immutability in the gem, not with `attr_readonly` | Accepted |
| [0007](0007-append-only-audit-trail.md) | Make the audit trail and the eligibility rows append-only | Accepted |
| [0008](0008-staged-multi-quorum-schema.md) | Model staged, multi-quorum approval from the first migration | Accepted |
| [0009](0009-host-owned-schema.md) | Let the host own the schema as an ordinary migration | Accepted |
| [0010](0010-operations-must-be-declared.md) | Require every operation to be declared in a registry | Accepted |
| [0011](0011-system-sentinel-actor.md) | Attribute gem-originated actions to a System sentinel actor | Accepted |
| [0012](0012-declared-error-taxonomy.md) | Declare the whole error taxonomy before raising any of it | Accepted |
| [0013](0013-json-runtime-pin.md) | Pin `json` to `~> 2.7` as a runtime dependency | Accepted |
| [0014](0014-executable-architecture-rules.md) | Enforce the architectural boundaries executably | Accepted |
