# ADR-0009: Let the host own the schema as an ordinary migration

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

An engine with tables has to get them into the host's database. The alternatives are to manage the
schema from inside the engine — migrating on boot, or keeping a private migration path — or to hand
the host a migration and let it run the same way as every other migration in the application.

Engine-managed schemas are opaque: they do not appear in the host's `schema.rb`, do not roll back
with the host's own `db:rollback`, and change the database as a side effect of deploying a gem
version.

## Decision

The gem ships a migration template. It is copied into the host's `db/migrate` and is thereafter the
host's file, run, rolled back and reviewed like any other. The gem never creates, alters or migrates
a table at runtime.

Two rules hold inside that migration:

- **No foreign key points at a host table**, and none ever will
  ([ADR-0003](0003-actor-references-as-triples.md)).
- Every foreign key *between* gem tables is `ON DELETE CASCADE`, so deleting a request removes its
  whole graph in one statement.

## Consequences

### Positive

- The schema is visible in code review, in `schema.rb`, and in whatever migration tooling the host
  already uses.
- It rolls back cleanly to zero and migrates straight back up, and leaves the host's own tables
  untouched when it does — both asserted by the suite.
- Installing the gem changes no data until someone runs a migration.

### Negative

- A host that installed an earlier version has to take later schema changes as further migrations,
  which the gem must ship and version carefully.
- A host can edit its copy. Divergence is possible and undetectable from inside the gem.
