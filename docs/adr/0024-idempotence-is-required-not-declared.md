# ADR-0024: Require idempotence of every target rather than declaring it per operation

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

A failed execution can be retried. Whether that is safe depends entirely on the target: running
`Member#update!` twice is harmless, charging a card twice is not.

`Operation` carried an `op.idempotent` flag, defaulting to `false`, intended to gate retries. By the
time execution was built, nothing read it — and writing the code that would have read it made the
problem visible. The flag is a promise about host code that the gem cannot verify, cannot test, and
would have to trust completely while deciding whether to repeat a side effect.

## Decision

The flag is removed. **Every change-request target must be idempotent**, and the README says so as a
contract rather than an option:

> A change-request target is a public singleton method that accepts keyword arguments only, and whose
> effect is idempotent — running it twice with the same payload leaves the same result as running it
> once.

- `retryable?` is `failed? && attempts.count < max_attempts`, and nothing else. The **retry ceiling
  is the only bound**, because it is the only one the gem can enforce.
- A host that cannot make a target idempotent leaves `op.max_attempts` at its default of `1` and gets
  one attempt. That is the same outcome `idempotent: false` would have produced, declared in terms of
  a number the gem actually acts on.
- A target declaring `change_request_id:` receives it, stable across every attempt, so one calling an
  external API can hand it over as that API's idempotency key. A per-attempt token would have defeated
  exactly the case retries exist for.
- `rake change_requests:verify` checks the checkable half of the contract — the constant resolves, it
  answers the singleton method dispatch will call, and it takes keyword arguments only. Idempotence it
  does not check, and does not pretend to.

## Consequences

### Positive

- One fewer setting whose value the gem has to believe. `max_attempts` is a number with observable
  behaviour; `idempotent: true` was an assertion with none.
- The requirement is stated once, in the README, where a host writing their first target reads it —
  rather than implied by a default they would have had to reason about.
- `Request#retryable?` needed no change when execution was finally built, because it had never
  learned about the flag.

### Negative

- **The gem now depends on a property it cannot check.** A host that writes a non-idempotent target
  and leaves `max_attempts` above 1 gets a double side effect, and nothing in the gem will have
  warned them. The flag would not have prevented this either — it would have recorded the same
  unverified claim — but its absence makes the reliance explicit rather than ceremonial.
- `max_attempts = 1` now carries two meanings: "this is cheap to retry but rarely worth it" and "this
  must never run twice". A reader of a declaration cannot tell which was meant.
- Removing a public attribute is a breaking change for anyone who set it. Acceptable only because
  nothing was released.
