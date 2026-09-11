# ADR-0006: Enforce creation-time immutability in the gem, not with `attr_readonly`

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

Twelve columns on `change_requests` are creation-time facts: what will be invoked, who asked, and
the labels snapshotted so the row stays readable once the actor and the payload's records are gone.
Changing any of them after the fact rewrites what a request *was*, which is the one thing an
approval gate exists to prevent.

Rails' `attr_readonly` **silently discards** the assignment unless the host application has
`config.active_record.raise_on_assign_to_attr_readonly` enabled — a setting an engine cannot
control, and silence is exactly the behaviour this column list exists to prevent.

## Decision

`Concerns::ReadonlyAttributes` declares the protected columns with `readonly_after_create` and
installs a `before_update` guard that raises `ChangeRequests::ReadonlyAttribute`, naming every
changed attribute at once.

`update_columns` bypasses it, by design: it bypasses callbacks everywhere in Rails, and a method
whose entire purpose is to skip the model layer should keep doing so.

## Consequences

### Positive

- The refusal is loud and identical in every host, whatever the host's ActiveRecord settings.
- The error is part of the gem's own taxonomy ([ADR-0012](0012-declared-error-taxonomy.md)), so a
  host rescues one hierarchy rather than two.
- It covers `jsonb` columns, which change by mutation as readily as by assignment.

### Negative

- One more `before_update` callback on the hot path of every save.
- Protection is application-level only. `update_columns`, raw SQL and a console session all go
  around it; a host wanting more has to add database rules itself.
