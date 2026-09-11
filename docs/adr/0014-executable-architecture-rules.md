# ADR-0014: Enforce the architectural boundaries executably

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

[ADR-0001](0001-headless-domain-core.md) is only true while it stays true. One `Rails.logger` in a
domain file, one `ActiveJob` reference outside a `defined?` guard, and the headless guarantee is
gone — with nothing failing, because the gem's own suite loads Rails for the dummy application and
would never notice.

The same applies to the guarantees that only exist at a process boundary: that requiring the gem
*without* Rails defines no engine, and that requiring it *with* Rails does.

## Decision

Two mechanisms, both wired into `rake ci`:

- **Static.** `Archspec.rb` states the boundaries as executable rules: every file under
  `lib/change_requests/` except `engine.rb` belongs to a `:domain` component that cannot reference
  `Rails`, `ActionController`, `ActionView`, `ActionDispatch` or `ActiveJob`, and cannot use the
  `:engine` component. New directories are added to the component as they appear, so a file outside
  the rules is a visible omission rather than a silent exemption.
- **Runtime.** Guarantees that depend on what a process loaded are asserted in **subprocesses**: a
  probe that boots a real Rails application and one that never requires Rails, each reporting facts
  the parent asserts. The isolation is the process, not the CI job.

`rake ci` runs RuboCop, archspec, Brakeman, the specs and a CVE check. CI runs the same tasks in at
most four jobs.

## Consequences

### Positive

- The boundary fails a build rather than being discovered by a host in production.
- The rules carry their rationale, so the check explains itself when it fires.
- Deliberate exceptions are per-line and annotated, which makes them countable.

### Negative

- A static analyser cannot see dynamic references, and reports a number of unresolved constants and
  unknown receivers it simply cannot judge.
- Subprocess probes are slower than ordinary examples and harder to debug, since a failure arrives
  as a string of reported facts rather than a stack trace.
