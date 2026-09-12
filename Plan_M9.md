# Plan M9b / M9c — cooldown and the inbox

Tickets for **M9b** (`op.cooldown` over both decisions) and **M9c** (the approver inbox), written against
`PLAN.md` §7.1, §5.3 and §5.9.

**M9a is not here.** It was pulled ahead of M4, and its three tickets live in `Plan_M4.md` — the linking
rule and the event timing were live defects rather than features, and every milestone after them displays
the number they got wrong. Both M9b and M9c depend on that work, and by the time either starts it has
shipped.

`PLAN.md` stays the source of truth. Where this document disagrees with it, that is a question in §6, not a
decision already taken.

---

## 1. Scope

| Milestone | Version | What it is                                                                                   | Spec        |
|-----------|---------|-----------------------------------------------------------------------------------------------|-------------|
| **M9b**   |         | `op.cooldown` over satisfaction **and** rejection, `CloseStageJob`, `close_due_stages!`, unapproval inside the window | §7.1        |
| **M9c**   | 0.10.0  | `Request.awaiting_approval_from`, the guard/scope equivalence spec, and the inbox in the UI   | §5.3, §11   |

Everything here is an **addition**. Unlike M9a, neither milestone fixes something that already ships
wrong: `op.cooldown` has never existed, and there has never been an inbox.

---

## 2. What M0–M9a leave standing

**Already built:**

- `Commands::EvaluateWorkflow` implements steps 0–4 of §7.1 **except** the cooldown branches — every
  `cooldown > 0` path is unreachable because the attribute does not exist.
- `change_request_stages.rejected_at` ships in the **first** migration and nothing writes it. M1a put it
  there deliberately: "one nullable timestamp added while M1 is unreleased is cheaper than a migration in
  every host application later."
- Step 0's rejection handling — including a rejected stage returning to `pending` — already ships, written
  at cooldown `0` where it is unreachable through the public API, "correct and cheap at every cooldown
  value" (Q35).
- `change_request_quorum_eligible_actors` rows, and the named-approver predicate that reads them.
- `close_stage_job.rb` is named in §2's layout and does not exist.
- **M9a has landed** (`Plan_M4.md`). The linking rule is a strict subset under `all_quorums`,
  `quorum_satisfied` is emitted where the transition happens, and named approvers go through the same
  rule — so M9b's windows and M9c's scope are both written against evaluation that is already correct.

**Declared but read by nothing:**

| Surface                                    | Declared in                   | Consumed by |
|--------------------------------------------|-------------------------------|-------------|
| `op.cooldown`                              | §6.4, §7.1; **no attribute**  | M9b-1       |
| `Stage#rejected_at`                        | the migration, §5.2           | M9b-3       |
| `Maintenance.close_due_stages!`            | §8, and M3b-2 named it as M9b's | M9b-5     |
| `Request.awaiting_approval_from`           | §5.3, §11, §14.4              | M9c-1       |
| `Testing` matcher `be_awaiting_approval_from` | `Plan_M7.md` M8-3, shipped pending | M9c-1 |

---

## 3. Build order

```
M9b-1  op.cooldown ─→ M9b-2  satisfied window ─→ M9b-3  rejected window ─┬─→ M9b-4  CloseStageJob
                                                                         └─→ M9b-5  close_due_stages!

M9c-1  awaiting_approval_from ─→ M9c-2  equivalence spec ─→ M9c-3  the inbox in the UI
```

M9b and M9c are independent of each other and can be done in either order.

---

## 4. Tickets — M9b: cooldown

### M9b-1 — `op.cooldown` and its configuration
**Spec:** §6.4, §7.1, §17.1
**Depends on:** M9a-2 (shipped ahead of M4)

**Deliver** the attribute that has been in §6.4's example since M1 and has never existed:

- `op.cooldown` on `Operation` — **minutes**, default `0`, integer, non-negative. Declaring a negative one
  is refused at declaration, as every other operation setting is.
- §6.4's callout that it raises `NoMethodError` is removed, and the attribute is added to `verify!`'s
  checks.
- **`verify!` gains the check §6.12 promised and M2-3 could not write**: a cooldown greater than zero
  requires ActiveJob, and declaring one without it fails with a `ConfigurationError`. That closes the half
  of §17.1's row that was waiting for the attribute to exist (ADR-0027 has the shape: the check belongs
  where the attribute is, not before it).
- `Commands::Create` snapshots nothing: cooldown is read live from the declaration at evaluation time,
  because a stage's window is a policy question and not a creation-time fact (**Q2**).

**Acceptance:** a cooldown of zero is the current behaviour exactly, asserted by the existing suite passing
untouched; a negative cooldown is refused at declaration; a non-zero cooldown without ActiveJob fails
`verify!`; the §6.4 callout is gone.
**Est:** 0.5 d

---

### M9b-2 — The satisfied window
**Spec:** §7.1
**Depends on:** M9b-1

**Deliver** step 3's `cooldown > 0` branch:

- A satisfied stage sets `satisfied_at` and **stays open**; the request does not advance.
- During the window an approver may unapprove. If that drops a quorum below threshold the stage returns to
  `pending`, `satisfied_at` is cleared, and any pending job becomes a no-op.
- `close_stage!` runs when the window elapses, not before — and everything it does today it still does.

**Acceptance:** a satisfied stage inside its window does not advance the request; an unapproval inside it
returns the stage to pending and clears `satisfied_at`; the same unapproval after closing is refused; at
cooldown `0` the stage is satisfied and closed in the same breath, as today.
**Est:** 0.75 d

---

### M9b-3 — The rejected window, and `rejected_at`
**Spec:** §7.1, §5.2
**Depends on:** M9b-2

**Deliver** the half §7.1 argues for most explicitly — "a mistaken rejection is at least as expensive as a
mistaken approval, and the plan gave only one of them a way back":

- A rejected stage sets **`rejected_at`**, the column M1a shipped for exactly this and nothing has ever
  written.
- The stage is `rejected` and cannot be satisfied, but **the request stays `pending`** and does not
  finalise until the window elapses.
- During it the rejector may unapprove their own rejection. When the last rejection on the stage goes, the
  stage returns to `pending`, `rejected_at` is cleared, **and the approvals already collected are still
  there to count** — step 0 already implements this half, unreachable until now.
- The typical loop, which is the point of the whole feature: rejected → the requester fixes it → the
  rejector withdraws and approves → everyone else's approvals still stand.

**Acceptance:** a rejected stage inside its window leaves the request `pending`; withdrawing the last
rejection returns the stage to `pending` with its approvals intact; the request finalises `rejected` when
the window elapses; at cooldown `0` the request is rejected in the same breath, as today;
`only_record_rejections` is unaffected by any of it.
**Est:** 0.75 d

---

### M9b-4 — `Execution::CloseStageJob`
**Spec:** §7.1
**Depends on:** M9b-3

**Deliver** the fast path, on the terms ADR-0027 already set for `Execution::Job`:

- Defined **only where ActiveJob is loaded**, Zeitwerk-ignored, required by the same loader. A cooldown
  greater than zero requires ActiveJob and `verify!` says so (M9b-1), so this is the one place the gem's
  behaviour genuinely depends on it.
- Enqueued at `satisfied_at + cooldown` or `rejected_at + cooldown`.
- **It re-evaluates on run rather than trusting its scheduling**: it does nothing if the stage is no longer
  satisfied or rejected, nothing if it is already closed, and nothing if the request is already final.
  Duplicate and late jobs are therefore harmless.

**Acceptance:** the job closes a stage whose window elapsed; it is a no-op for a stage that reverted, one
already closed, and a request already final; running it twice changes nothing; a headless process with a
cooldown declared fails `verify!` rather than enqueueing into nothing.
**Est:** 0.5 d

---

### M9b-5 — `Maintenance.close_due_stages!`
**Spec:** §7.1, §8
**Depends on:** M9b-4

**Deliver** the guarantee beneath the fast path, and the fourth sweeper M3b-2 listed and deliberately did
not build:

- Settles any stage whose `satisfied_at + cooldown` or `rejected_at + cooldown` has passed.
- **A lost job is not harmless** — the stage would stay decided-but-open forever — so acting does not
  depend on the job alone. The job is the fast path; the sweeper is the guarantee. This is the same pattern
  as the stuck-execution reaper (§8), and it gets the same shape: a query, a guard, a command.
- A `change_requests:close_due_stages` rake task, and a line in `docs/05`'s crontab beside the other two
  scheduled sweeps. It belongs on cron: it decides nothing, it only acts on a deadline that has already
  passed (ADR-0028's test for schedulability).

**Acceptance:** it settles a stage whose window elapsed and leaves one whose window has not; it agrees with
`CloseStageJob` on every case, asserted by running both against the same fixtures; the crontab in `docs/05`
gains it.
**Est:** 0.75 d

---

## 5. Tickets — M9c: the inbox

### M9c-1 — `Request.awaiting_approval_from`
**Spec:** §5.3, §11, §14.4
**Depends on:** M9a-1 (shipped ahead of M4)

**Deliver** the approver inbox as **an indexed, paginatable scope** — not a Ruby filter over every open
request:

- `Request.awaiting_approval_from(actor)` returns the requests whose **current** stage holds a pending
  quorum the actor qualifies for, by permission **or** by name.
- Expressed in SQL against the eligibility rows, which is the reason eligibility is rows at all (§5.3): the
  same predicate serves the guard and the query.
- It composes with `visible_to` (M4-3) and excludes undeclared operations, as `visible_to` already does.
- The actor's permission set comes from their registered type's lambda and is passed into the query; the
  gem does not read permissions in SQL.

**Acceptance:** the scope returns exactly the requests `Guards::Approve` permits, for every cell of the
eligibility 2×2 across all three dummy actor classes; it composes with `visible_to`; it uses the indexes,
asserted by explaining the query rather than by hoping.
**Est:** 1 d

---

### M9c-2 — The guard/scope equivalence spec
**Spec:** §5.3, §15.2
**Depends on:** M9c-1

**Deliver** the spec §5.3 calls the whole reason eligibility is data:

- Across the full 2×2 of nullable `permission` × `actor_type`, under both `match` modes, across all three
  dummy actor classes, **and with named approvers OR-ed in**: `Guards::Approve#allowed?` and
  `Request.awaiting_approval_from` must agree on every cell.
- Table-driven, one `where` per row, in the shape `guards_spec.rb` already uses.
- **It must fail when either side is changed alone**, which is the only way to know it is doing anything.

**Acceptance:** every cell agrees; breaking the guard alone fails it; breaking the scope alone fails it;
the table covers named approvers and the `all_quorums` linking rule M9a-1 introduced.
**Est:** 0.5 d

---

### M9c-3 — The inbox in the UI
**Spec:** §11, §12
**Depends on:** M9c-2, M6a-4

**Deliver** the filter M6a shipped without (**Q3**):

- A fifth index filter, `awaiting=me`, applying `awaiting_approval_from(current_actor)`.
- Stage and quorum progress on the index row, which §17's M9c line names — the index currently shows a
  status pill and nothing about how far through the workflow a request is.
- `ChangeRequests::Actor#change_requests_awaiting_approval` (M4-4 named it and left it for this milestone).
- `Testing`'s `be_awaiting_approval_from` matcher is **un-pended** (`Plan_M7.md` M8-3, Q4).

**Acceptance:** the filter narrows to exactly what the scope returns; the count matches the guard for the
acting actor; the matcher is un-pended and passes; the index query count does not grow with the filter
applied.
**Est:** 0.5 d

---

## 6. Questions

**Two raised, two answered.** M9a's own question moved to `Plan_M4.md` with its tickets.

| ID     | Question                                                                 | Answer                                                                                                                                                                                                                                                       |
|--------|---------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Q1** | Is `cooldown` snapshotted onto the request at creation, like `max_attempts` and `expires_at`? | **No, read live.** `max_attempts` and `expires_at` are snapshotted because they bound a request's own lifetime and must not move under it. A cooldown is a *reversibility window on a decision that has not happened yet*, and a host shortening it should see the change take effect. §6.12 point 4's frozen snapshot covers the approval policy, which this is not. |
| **Q2** | `Plan_M6.md` asks whether the index needs `awaiting_approval_from` before M9c. | **No — M9c-3 adds it, and M6a ships without it.** Pulling the scope forward means writing M9c-1 during M6, which is the ticket in this milestone with real SQL in it. The cost is that the index ships for two milestones without the filter most users want, and that is worth saying in `docs/06` rather than hiding. |

### Changes these answers make to `PLAN.md`

| Section  | Change                                                          | From |
|----------|------------------------------------------------------------------|------|
| **§6.4** | The "not built yet" callout on `op.cooldown` is removed          | M9b-1 |
| **§6.12**| Point 6's cooldown/ActiveJob check is built                      | M9b-1 |

---

## 7. Estimate

| Milestone | Tickets | Days     |
|-----------|---------|----------|
| M9b       | 5       | 3.25     |
| M9c       | 3       | 2.0      |
| **Total** | **8**   | **5.25** |

Against §17's 2–3 d + 2 d = 4–5 d. M9a's 2.25 d moved to `Plan_M4.md` with its tickets.

**M9b is five tickets because cooldown is two features**, not one: §7.1 gives satisfaction and rejection
their own windows, their own clearing rules and their own halves of step 0 — and the rejection half is the
one the plan argues for hardest and the one nothing has ever exercised.

---

## 8. Open questions for the maintainer

Nothing here blocks ticket work; each is a judgement worth making before the ticket that depends on it.

1. **Is `op.cooldown` in minutes the right unit?** §6.4 and §7.1 both say minutes, and a cooldown shorter
   than a minute is probably meaningless — but `expires_in` is seconds and `older_than` is seconds, so the
   gem would carry three time settings in two units. Worth settling before M9b-1 writes the attribute.
2. **Does a cooldown interact with `expires_at`?** A stage satisfied at minute 59 of a cooldown that ends
   after the request's expiry is an unanswered case: the expiry sweeper would expire a request whose stage
   is about to close. §7.1 and §8 do not mention each other here.
3. **What does the UI show during a cooldown window?** A satisfied-but-open stage is a state the show page
   has no vocabulary for — it is neither "current" nor "satisfied" in the sense `Value::StageProgress`
   carries — and M6b-2 will have shipped before M9b exists. That is either a new tone, a countdown, or
   nothing, and it is a design decision rather than a ticket.
