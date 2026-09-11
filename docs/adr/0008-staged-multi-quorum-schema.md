# ADR-0008: Model staged, multi-quorum approval from the first migration

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

The common case is "two people with this permission must approve". The cases that arrive later are
"one Admin **or** two Owners", "one Admin **and** two Owners, then a Director", and "only these two
named people". A `required_approvals` integer on the request row expresses the first and none of the
others.

Retrofitting stages onto a shipped gem means a schema migration in every host application, plus a
data migration for every request in flight.

## Decision

The schema is staged and multi-quorum from the first migration. A request has ordered **stages**; a
stage has one or more **quorums**; a quorum is a threshold plus an eligibility set, expressed as
permission rows (permission × actor type, independently nullable) and named-actor rows.

- Stages are always sequential. Parallelism within a step is one stage holding several quorums;
  ordered groups are consecutive stages. There is no request-level mode column.
- A stage's `satisfied_by` is `any_quorum` or `all_quorums`. One word is the whole difference
  between "OR" and "AND".
- Counting approvals is the only rule. There is no rule column and no expression language.

A flat 1-of-N request is simply a request with one stage holding one quorum.

## Consequences

### Positive

- Every workflow shape the gem intends to support is already representable; later milestones add the
  declaration syntax and the evaluation, not tables.
- Approval policy is never duplicated onto the request row. The stage and quorum rows *are* the
  frozen snapshot ([ADR-0007](0007-append-only-audit-trail.md)).

### Negative

- Five tables where one integer column would have served the common case, and four joins to answer
  "can this person approve?".
- Creating a request writes a small graph rather than a row.
