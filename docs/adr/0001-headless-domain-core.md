# ADR-0001: Keep the domain core headless

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

Approval workflows are triggered from more places than a controller: a rake task, a console session,
a background job, an API client. A gem whose domain logic can only load inside a booted Rails
application forces every one of those callers through a framework it does not otherwise need, and
makes the gem's own test suite slower and less honest than it should be.

ActiveRecord is unavoidable — the gem owns nine tables. The rest of Rails is not.

## Decision

Everything under `lib/change_requests/` except `engine.rb` is domain code and loads with `Rails`
undefined. The entrypoint requires only `active_record` and `zeitwerk`, then calls
`ChangeRequests.load_engine!`, which returns early unless `::Rails::Engine` is already defined.
Loading the Rails layer is therefore opt-in and driven by the host's own boot order.

Because `require` fires once, `load_engine!` is public and idempotent: a host that requires this gem
before Rails exists can call it again afterwards.

## Consequences

### Positive

- The domain runs from any process that can open a database connection.
- No domain file may name `Rails`, `ActionController`, `ActionView`, `ActionDispatch` or
  `ActiveJob`; see [ADR-0014](0014-executable-architecture-rules.md) for how that is enforced.
- The headless path is exercised for real: an integration spec migrates the schema and builds a
  request graph in a subprocess that never requires Rails.

### Negative

- Conveniences that are free inside Rails — `I18n`, time zones, ActiveJob — must be reached
  defensively or declared optional. `ChangeRequests::Translation` exists only for that reason.
- The two Rails-facing references the entrypoint is allowed are `defined?`-guarded and must stay
  that way, which is easy to regress and needs an explicit rule to prevent.
