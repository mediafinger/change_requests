# ADR-0012: Declare the whole error taxonomy before raising any of it

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

Hosts rescue this gem's errors in one place — typically `rescue_from ChangeRequests::Error` in a
controller, with finer branches for the cases they handle specially. That code depends on the
*ancestry* of each error class, not just its name. Introducing `NotApprovable` in one milestone as a
`StandardError` and re-parenting it under `TransitionError` in the next silently changes which
`rescue` clause catches it in every host that upgraded.

## Decision

`errors.rb` declares the complete hierarchy up front, including errors no milestone raises yet.
Everything descends from `ChangeRequests::Error`; refused transitions descend from
`TransitionError`, execution failures from `ExecutionError`.

`TransitionError` carries `#request` and `#reason`. **`reason` is the contract** — controllers branch
on it and views render it as a disabled button's tooltip — while the message is for humans and is
translated through the same key the guard uses, so a disabled button and a raised error cannot word
the same refusal differently.

Errors raised for unsupported operations rather than refused domain transitions stay in ActiveRecord's
taxonomy; see [ADR-0007](0007-append-only-audit-trail.md).

## Consequences

### Positive

- A host's `rescue` clauses keep meaning the same thing across gem versions.
- The taxonomy doubles as a specification of what can go wrong, readable in one file.
- Guard and command cannot disagree about why something was refused.

### Negative

- Classes exist that nothing raises yet, which reads as dead code until the milestone that uses them
  lands.
- The reason symbols are now public API and have to be versioned as carefully as the class names.
