# ADR-0019: Refuse the requester by identity, and make only execution configurable

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

The point of an approval workflow is that somebody other than the requester agrees. A setting that
turns that off — `requester_may_approve` — is an argument waiting to happen: it implies the gem has
an opinion that could reasonably be overridden, and it would be set to `true` in exactly the
installations where four eyes mattered most.

Execution is a different question. Running an approved change is not a second opinion, and plenty of
sound processes have the person who asked for it press the button once others have agreed.

Both questions are the same underlying one — is this the same human twice — and that question is not
answerable from `(type, id)` alone when a host has several actor classes backed by one person.

## Decision

**The requester can never approve their own request**, and there is no setting to the contrary: no
reader, no writer, no constant. `Guards::Approve` compares identity and consults nothing. Naming the
setting, even to hard-code it to `false`, would imply it were negotiable.

**Execution is configurable**, in three independent places:

- `t.may_execute` on the registered actor type — whether this *class* of actor may execute at all,
  checked before the separation-of-duties branches so a class declared unable to execute never passes
  a guard a presenter consults.
- `config.requester_may_execute`, default `false`.
- `config.approver_may_execute`, default `true`. "An approver" means someone who wrote a row in
  `change_request_approvals` — who actually spent a decision — not merely someone eligible to.

**`config.actor_identity` is the opt-in answer to "the same human twice".** When a host supplies it,
it stands in for `(type, id)` in three places: refusing the requester as an approver, refusing a
second decision on one stage, and `Execute`'s separation-of-duties branches. All three go through one
helper, `Guards::Base#same_person?`, so they cannot answer differently.

It is deliberately **not** consulted by `Unapprove`. Identity decides who counts as one person when
tallying decisions; retracting is about which row this actor wrote, and letting one actor delete
another's row would make the trail say something untrue.

## Consequences

### Positive

- The gem's central promise is not a configuration value, so it cannot be turned off by an
  initializer nobody reviewed.
- Hosts with several actor classes over one identity get the cross-class rules by supplying one
  lambda, and hosts without one lose nothing they had.
- Separation of duties for execution is expressible without weakening approval.

### Negative

- The database's unique index on `(stage, approver_type, approver_id)` cannot express identity, so
  under `config.actor_identity` the guard is deliberately stricter than the constraint behind it. A
  caller bypassing the guard could still write the second row.
- Three settings govern execution and their interaction is only legible by reading the guard's branch
  order.
- A host that genuinely wants self-approval — a single-operator installation, say — has no route to
  it and must not use the gem for that workflow.
