# ADR-0015: Consult one guard object for every transition

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

Every transition is asked about twice: once by the view, to decide whether the button is enabled,
and once by the command, to decide whether the write happens. Answering it twice means two
implementations of the same rule, and the failure mode is a button that offers something the command
then refuses — with different wording, or no wording at all.

The rules themselves are not one condition but an ordered list of them. "You cannot approve this"
covers a finished request, a request on another stage, a decision already given, and an actor with
no standing at all. Which of those a person is told is the whole of the user experience.

## Decision

One guard class per transition, under `lib/change_requests/guards/`, constructed as
`(request:, actor:, **options)`. It answers `allowed?`, `reason` and `check!`, and both the command
and the presenter build the same object.

- A subclass implements `refusal`, which returns `nil` to permit or a symbol from
  `Guards::Base::REASONS`, the closed shared vocabulary. Branch order inside `refusal` is part of
  the contract: it decides which of several true refusals the person is shown.
- `refuses_with` declares the error class, rather than deriving it from the guard's name —
  `Comment` and `Expire` refuse with `NotAuthorized`, the decision guards with their own
  `TransitionError` ([ADR-0012](0012-declared-error-taxonomy.md)).
- One reason overrides that declaration: `:already_finalized` always raises `AlreadyFinalized`,
  whichever guard produced it, so a host rescuing "this request is over" catches every command. It
  is the same class and the same reason the model's terminal-state guard raises underneath.
- The undeclared-operation refusal lives in `Guards::Base` and runs before `refusal`, so no guard
  repeats it. `Comment` opts out with `exempt_from_undeclared_operation!` — a request stranded by a
  removed declaration is exactly the one someone needs to leave a note on.

**There is no `Guards::Create`.** A guard asks "may this actor do X *to this row*", and at creation
there is no row. `Commands::Create` runs the three equivalent checks inline. The presenter's half of
the question — may this actor raise a request at all — is a property of the operation and the actor's
registered type, and will be answered by `Operation#requestable_by?` reading the same
implementation, not by a guard carrying a second signature.

## Consequences

### Positive

- A disabled button and a raised error cannot disagree, because they are the same object.
- `reason` is a symbol, so a host branches on it without parsing English, and the wording is a
  translation rather than a string in the code ([ADR-0020](0020-refusal-vocabulary-and-fallback.md)).
- One shape for every guard means one shared example can run against all of them — which is how the
  undeclared-operation exemption and the cross-guard reason table are asserted at all.

### Negative

- `REASONS` is public API. A symbol cannot be renamed without breaking host code that branches on
  it, and the vocabulary grows monotonically.
- Branch order is load-bearing but invisible: nothing in the type system says `:already_finalized`
  must precede `:not_pending`, only a cross-guard spec that asserts the two answers line up. They
  had already drifted once before that spec existed.
- A guard resolves the acting actor through the registry, so an unregistered class raises
  `UnknownActorType` rather than producing a refusal. The allowlist is deliberately not a reason.
