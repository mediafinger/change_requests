# Architecture Decision Records

One record per significant architectural choice: its context, the decision, and what it costs.

These describe the gem **as it stands today**. Decisions still ahead of the implementation live in
`PLAN.md` until the code that makes them real exists.

A record is never rewritten once accepted: a decision that is reversed is **superseded** by a later
record, which links back to it. A record may still be **corrected** where it describes the code
inaccurately — these describe the gem as it stands, and a wrong statement left in place is worse
than an edit.

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
| [0015](0015-one-guard-object-per-transition.md) | Consult one guard object for every transition | Accepted |
| [0016](0016-commands-are-the-only-writers.md) | Make commands the only writers, under one lock and one event path | Accepted |
| [0017](0017-approvals-count-through-links.md) | Count approvals only through the links written at decision time | Accepted |
| [0018](0018-eligibility-is-data.md) | Express eligibility as data, with one implementation of the predicate | Accepted |
| [0019](0019-separation-of-duties.md) | Refuse the requester by identity, and make only execution configurable | Accepted |
| [0020](0020-refusal-vocabulary-and-fallback.md) | Ship refusal reasons as a closed vocabulary that degrades to the symbol | Accepted |
| [0021](0021-serialise-commands-let-the-index-arbitrate.md) | Serialise commands with a row lock and let the unique index arbitrate | Accepted |
