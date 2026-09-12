# ADR-0025: Verify declarations at boot, from the same checks the runtime reads

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

An operation can be wrong in ways nothing notices until the worst moment. A `service` naming a
constant that does not exist fails when someone finally executes a request two approvals in. A
workflow with no stages produces a request that can never leave `pending`.

`Commands::Create` already refused some of these at creation, in its own words. §6.12 promised a
boot-time `verify!` that would refuse more of them. Written independently, those two would answer the
same question differently — and a third reader was already planned, `Operation#requestable_by?` for
the "raise a request" button that has no guard to consult.

## Decision

One set of checks, split by what they need in order to run:

- **`Operation#problems`** — everything checkable without loading the host's classes: a `version`, a
  `service`, a `method_name`, a non-empty workflow, a positive threshold on every quorum. Read by
  `validate!` at declaration, by `Commands::Create` at creation, and by `verify!` at boot. An
  incomplete operation therefore never enters the registry at all; `Create`'s check is the backstop
  for one edited afterwards.
- **`Operation#target_problems`** — what needs the host's classes loaded, so it runs at boot and
  nowhere else: the constant resolves, and it answers the public singleton method dispatch will call,
  taking keyword arguments only. Constantizing during declaration would hold references to classes an
  initializer has not finished defining, and in a reloading application to classes about to be
  replaced.
- **`Execution::TargetContract`** holds the target half and its wording, read by `verify!` at boot and
  by `Execution::Dispatcher` at dispatch. The two cannot describe the same defect differently.
- `Operations#verify!` raises one `ConfigurationError` listing every problem across every operation,
  the shape `Configuration#validate!` already uses. A host that has seen one has seen both.
- Two entry points: `rake change_requests:verify` for CI and deploys, and a `to_prepare` hook
  registered in the engine and gated on `Rails.env.local?`. Production runs the task instead, because
  `verify!` constantizes every declared service and a booted application should not pay for that on
  every request cycle.

## Consequences

### Positive

- A misconfigured operation fails in CI, or on the next reload in development, rather than on the
  first execution of a request someone has already approved.
- Boot-time and creation-time cannot word the same defect differently, because they read the same
  method — asserted by a spec that compares the two messages.
- The `to_prepare` hook holds nothing across a reload, which is proven by replacing the resolved
  class and watching the next run refuse.

### Negative

- `validate!` growing to the full `#problems` set made declaration stricter than it was. Every
  incomplete fixture in the suite had to gain a service and a workflow, and a host that liked
  declaring an operation in pieces across two initializers no longer can.
- **`verify!` does not check everything §6.12 claims.** An unsatisfiable `all_quorums` stage is still
  unchecked, because "unsatisfiable" is undecidable once permission rows are involved — eligibility is
  a host runtime question. The gap is recorded in §17.1 rather than papered over.
- The `to_prepare` hook runs on every reload in development, so a large registry pays a constantize
  per cycle. Cheap today; a host with hundreds of operations may disagree.
- Three readers of `#problems` means changing it changes three behaviours at once. That is the point,
  and it is also the risk.
