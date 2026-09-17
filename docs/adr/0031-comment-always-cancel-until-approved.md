# ADR-0031: Let anyone comment, and let cancelling end when the last stage closes

- **Status:** Accepted
- **Date:** 2026-09-17

## Context

Comment and Cancel both answered "the requester, or any eligible approver". Eligibility was computed
from the quorums still **pending** on the current stage, plus every other stage. So an approver whose
quorum was met stopped being eligible: whoever closed the only stage could neither comment on nor cancel
the request they had just approved. The rule said "eligible approver" and the code meant "approver still
needed".

Cancel also stayed open on an `approved` request. By then the workflow is finished: whether it runs is a
matter for Execute and Expire, and cancelling it undoes every approval without any of the approvers
deciding anything.

## Decision

- **`Guards::Comment` permits any registered actor on any request**, in every status, including a request
  whose operation is no longer declared. A comment writes no lifecycle state, and `visible_to` already
  decides who can see the request ([ADR-0030](0030-visibility-is-a-scope.md)). An unregistered class still
  raises `UnknownActorType`, which is the allowlist rather than a reason.
- **`Guards::Cancel` refuses with `:approval_complete` once the last stage has closed**, unless the request
  `failed`. A failed run is worth calling off. The check reads the **stage row** (`closed?`), not the
  request status. `already_finalized` and `executing` keep precedence, and the refusal applies to
  undeclared operations too.
- **Standing for Cancel counts every quorum on every stage, satisfied or not**
  ([ADR-0018](0018-eligibility-is-data.md)).

## Consequences

### Positive

- An approver can always annotate the request they approved, and anyone who can see a request can leave a
  note on it.
- An approved request can no longer be quietly called off after everyone signed.

### Negative

- Comments are no longer gated by standing. A host that wants that has to narrow `visible_to` or wrap the
  command.
- `:approval_complete` is a new public reason symbol ([ADR-0020](0020-refusal-vocabulary-and-fallback.md)).
- Reading the stage row means M9b's cooldown changes the answer: a satisfied stage waiting to close
  leaves the request cancellable for the length of the window. That is intended, and M9b has to revisit it.
