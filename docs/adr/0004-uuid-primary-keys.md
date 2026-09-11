# ADR-0004: Use uuid primary keys for every gem-owned table

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

The gem creates nine tables in the host's database. An earlier draft let the host choose between
uuid and bigint at install time, via a `--primary-key-type` flag on the install generator. That
choice doubles the schema surface under test, has to be threaded through every foreign key in the
migration template, and was never actually asked for.

## Decision

Every gem-owned primary key and every foreign key between gem-owned tables is a `uuid`. There is no
install-time flag and no bigint variant.

This says nothing about the host's own tables. `config.actor_type … t.key_type` is a different
setting, describing how a host record's key is cast into the gem's string `*_id` column
([ADR-0003](0003-actor-references-as-triples.md)).

## Consequences

### Positive

- One schema shape to test, document and migrate.
- A request id is safe to put in a URL, and is what execution hands to targets declaring a
  `change_request_id:` keyword, so no separate idempotency key column is needed.

### Negative

- Requires `gen_random_uuid()`. PostgreSQL 13 and later provide it natively; an older host has to
  enable `pgcrypto` itself, because the migration does not enable extensions in the host's database.
- Wider indexes, and no natural insertion order — `created_at` is the ordering column everywhere.
- A host that keys everything else with bigints gets a mixed convention it did not choose.
