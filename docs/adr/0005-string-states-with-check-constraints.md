# ADR-0005: Store states as strings with CHECK constraints, not PostgreSQL enums

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

Seven columns hold a closed set of values: a request's `status`, a stage's `status` and
`satisfied_by`, a quorum's `status` and `permission_match`, an approval's `decision` and an
attempt's `outcome`. The obvious database-native answer is a PostgreSQL enum type.

The gem is an engine, so its schema lives in other people's applications. A milestone that adds one
state to one of those sets would then require an `ALTER TYPE` migration in every host that installed
the gem.

## Decision

Those columns are `string`, constrained twice:

- a `CHECK` constraint in the migration, so the database refuses an unknown value;
- a `Concerns::StringEnum` declaration in the model, which adds an inclusion validation, a scope and
  a predicate per value.

`StringEnum` is not Rails' `enum`: it leaves the column's own reader and writer alone, maps nothing
through a hash, and reports an unknown value as a validation error rather than raising at
assignment.

`kind` on the event table is deliberately *not* in this list. It is a validation only, because later
milestones add kinds and a CHECK would make each one a migration in every host application.

## Consequences

### Positive

- Adding a state is a model change plus one CHECK migration, not a type change coordinated across
  every installation.
- Values read as themselves in `psql`, in logs and in the audit trail.
- The set is enforced at both layers, so a direct `INSERT` cannot write an unknown state.

### Negative

- Wider columns than an enum's four bytes, and the set is declared in two places that must agree.
- Nothing stops a host from dropping a CHECK constraint and writing whatever it likes.
