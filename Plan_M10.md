# Plan M10 / M11 — notifications, and the first public release

Tickets for **M10** (`config.on_event`, `ActiveSupport::Notifications`) and **M11** (the docs set, the
README, the CHANGELOG and versioning policy, RBS, and the release itself), written against `PLAN.md` §10,
§5.5 and §18.

**M11 releases 0.12.0, not 1.0.0.** Everything in §18's "In" list will have shipped, but nothing will have
been used by an adopter — and 1.0 is a promise of stability on a surface nobody has pushed on. 1.0 waits
for real-world experience with the gem; M11 is what makes that experience possible.

`PLAN.md` stays the source of truth. Where this document disagrees with it, that is a question in §6, not a
decision already taken.

---

## 1. Scope

| Milestone | Version    | What it is                                                                             | Spec      |
|-----------|------------|-----------------------------------------------------------------------------------------|-----------|
| **M10**   | 0.11.0     | `config.on_event` after commit, `ActiveSupport::Notifications`, and `docs/08`'s worked example | §10, §5.5 |
| **M11**   | **0.12.0** | The docs set, README with screenshots, CHANGELOG, versioning policy, RBS in `sig/`, the first public release | §18, §2   |

**1.0.0 is deliberately not this milestone.** It is a separate, later decision, taken once adopters have
used the gem — see §8.

**The maintenance rake tasks that §17's M10 row used to carry shipped early, in M3b.** What remains here
is notifications and nothing else.

---

## 2. What M0–M9 leave standing

**Already built:**

- **`Commands::Base#emit` is the single write path for events**, enforced by a spec that scans `lib/` and
  fails if any other file writes one (ADR-0016). M10 hooks one place, not fifteen.
- Every event row is complete on its own: the actor triple, `operation_version` read live at write time,
  `occurred_at`, `body` and `metadata`. `docs/08` already argues the table "exports alone as a complete
  log, with no join required" — which is most of the answer to §17.1's M10 question.
- `Event` is immutable: `Concerns::Immutable` refuses updates and destroys, and `Event.by_system` and
  `#system_actor?` already exist.
- `ChangeRequests::Testing.capture_events` ships **inert** from M8-6, written to bypass a hook that does
  not exist yet (`Plan_M7.md`, Q5). M10 is what makes the bypass mean something.
- `docs/08_events_and_notifications.md` exists and closes with "`config.on_event` and
  `ActiveSupport::Notifications` arrive with M10."

**Declared but read by nothing:**

| Surface                       | Declared in                   | Consumed by |
|-------------------------------|-------------------------------|-------------|
| `config.on_event`             | §10 only; **not on `Configuration`** | M10-1 |
| `config.instrument`           | §10 only; **not on `Configuration`** | M10-2 |

**One stale statement to fix.** `docs/08`'s kinds list still contains **`stage_closed`**, which M1b removed
when it turned out nothing emitted it (commit "Remove the stage_closed event kind"). `Event::KINDS` has
fifteen entries; the document lists sixteen. M10-4 fixes it, and M10-4's acceptance makes it impossible to
drift again.

---

## 3. Build order

```
M10-1  the payload contract + on_event ─→ M10-2  instrumentation ─→ M10-3  after_commit and isolation
                                                                 └→ M10-4  docs/08

M11-1  docs 01/02/03/09/10 ─┬─→ M11-2  README ─→ M11-5  release
M11-3  CHANGELOG + semver ──┤
M11-4  RBS ─────────────────┘
```

---

## 4. Tickets — M10: notifications

### M10-1 — The event payload, and `config.on_event`
**Spec:** §10, §5.5, §17.1
**Depends on:** nothing

**Deliver** the hook §10 documents, and settle what it receives (**Q1**, which closes §17.1's M10 row):

```ruby
config.on_event = ->(event) { ChangeRequestMailer.notify(event).deliver_later }
```

- **It receives the `Event` record itself**, with `change_request` preloaded and nothing else.
- `event.change_request` is loaded before the callback runs, because a notification that does not need the
  request is rare and one that lazily loads it inside a mailer is an N+1 nobody sees. **No other
  association is preloaded**: stages, quorums and approvals would make every emit pay for what most hooks
  never touch, and a hook that needs them can ask.
- `validate!` checks it is callable or nil, and that it takes one argument.

**Acceptance:** the hook fires once per event with the event; `change_request` is loaded without a query
inside the callback, asserted by counting; a nil hook is the default and costs nothing; `validate!` refuses
a non-callable and an arity that cannot accept the event.
**Est:** 0.5 d

---

### M10-2 — `ActiveSupport::Notifications`
**Spec:** §10
**Depends on:** M10-1

**Deliver** the instrumentation half, "emitted from the same place" as the hook:

- `config.instrument` (default `true`), instrumenting `change_requests.<kind>` — `change_requests.approved`,
  `change_requests.executed`, and so on, one per `Event::KINDS` entry.
- The payload is a **Hash**, because that is what `ActiveSupport::Notifications` subscribers expect:
  `{ event:, change_request:, kind:, actor:, occurred_at: }`. The record goes in it, so a subscriber has
  the same access the hook has.
- Emitted around the commit, not inside the command's transaction (M10-3), so a subscriber's timing
  reflects when the fact became true rather than when it was written.
- `ActiveSupport::Notifications` is part of ActiveSupport, which is already a runtime dependency — this
  needs no optionality dance, unlike ActiveJob (ADR-0027).

**Acceptance:** one notification per event with the documented payload; `instrument = false` emits none;
every kind produces its own event name, asserted against `Event::KINDS` so a new kind cannot ship
uninstrumented.
**Est:** 0.5 d

---

### M10-3 — After commit, and failure isolation
**Spec:** §10
**Depends on:** M10-2

**Deliver** the delivery guarantee §10 states, which is the whole reason this ticket is separate:

- **Both are called `after_commit`, never inside the command's transaction.** "A notification that raises
  must not roll back an approval, and a mailer must not see a row that a later failure will discard."
- A hook that raises does not propagate into the command. It is logged and swallowed (**Q2**) — the
  approval already happened, and re-raising would report a failure that did not occur.
- Events emitted inside a transaction that then rolls back fire **nothing**: the hook is registered on the
  transaction, not on the write.
- **Hosts enqueue rather than send inline.** The gem does not wrap the callback in a job for them, because
  queue choice and retry policy belong to the host — but the README and `docs/08` say so at the call site,
  because an inline mailer in `on_event` is the mistake this design invites.
- `Testing.capture_events` (M8-6) stops being inert: it collects without invoking the hook.

**Acceptance:** a command that raises after `emit` fires no notification; a hook that raises leaves the
command's result intact and is logged; a nested transaction rolling back fires nothing; `capture_events`
collects without invoking `on_event`, asserted by a hook that would fail the spec if called.
**Est:** 0.75 d

---

### M10-4 — `docs/08`'s notification half
**Spec:** §10, §5.5
**Depends on:** M10-3

**Deliver** the section `docs/08` promises, and the correction it needs:

- A worked example: wiring `overridden` to Slack or email on day one, which §8.1 calls "the single event
  most worth alerting on".
- The payload contract from M10-1 and M10-2, written out.
- The inline-versus-enqueued guidance, with the failure it prevents.
- **The kinds list is corrected**: `stage_closed` has not existed since M1b, and the document still lists
  it. A spec compares the documented list against `Event::KINDS` in both directions, so the next kind
  cannot ship undocumented and a removed one cannot linger.

**Acceptance:** the kinds list and `Event::KINDS` agree, checked programmatically; the worked example runs;
`stage_closed` appears nowhere.
**Est:** 0.5 d

---

## 5. Tickets — M11: the first public release

### M11-1 — The docs set
**Spec:** §2, §18
**Depends on:** M10-4

**Deliver** the five documents §2's layout names and nothing has written. By M11, five of ten exist:
`04` (M4-5), `05` (M3b-3), `06` (M6b-6), `07` (M8-7), `08` (M3b-2, M10-4).

| Document                                       | What it has to cover                                                            |
|------------------------------------------------|----------------------------------------------------------------------------------|
| `01_getting_started.md`                        | install, declare one operation, raise, approve, execute — in that order, running |
| `02_operations.md`                             | `op.workflow` in full, `verify!`, versioning, payload labels, the target contract |
| `03_approval_workflows.md`                     | §6.9's four shapes, cooldown, rejection, override — the policy cookbook           |
| `09_upgrading.md`                              | the semver policy applied: what changes between majors and what `migration_upgrade` does |
| `10_migrating_an_existing_implementation.md`   | §20's salvage notes turned outward: moving from a hand-rolled approval table      |

- **Every code sample runs**, asserted by extracting and executing them, in the shape M8-7 establishes for
  `docs/07`. A documentation set nobody executes is a documentation set that is wrong within two releases.
- `03` is the one worth the most: it is where a host decides between a quorum and an override (§6.9c
  versus §8.1), which is the decision the gem exists to make legible.

**Acceptance:** every sample runs; every document links to the ADRs behind its decisions; the set is
complete against §2's layout.
**Est:** 2 d

---

### M11-2 — The README
**Spec:** §18
**Depends on:** M11-1

**Deliver** the README an evaluator reads for ninety seconds:

- What it does, in three sentences, above the fold.
- A worked example end to end — declare, request, approve, execute — short enough to read whole.
- Screenshots of the index and show pages, from `bin/demo` (M6c-6).
- **What 0.12.0 means**: feature-complete against §18's cut line, documented, and asking for the feedback
  1.0 will be based on. An evaluator should know they are early, not discover it.
- **The non-goals list, verbatim from §18**: typed payload validation, delegation, escalation and
  reminders, a conditional-routing rules engine, weighted quorum, bulk approval, non-PostgreSQL adapters,
  Phlex/ViewComponent satellites, an admin dashboard, a full transactional outbox. "It tells an evaluator
  in ninety seconds whether the gem fits."
- The requirements, stated plainly: **PostgreSQL only**, Rails 8.1, Ruby 4.0.
- The target contract and the crontab, both already there from M2-0 and M3b-3, kept and linked rather than
  restated.
- The six-tier UI story in one table, linking to `docs/06`.
- The "WORK IN PROGRESS" banner is removed — which is the smallest diff in this milestone and the one that
  means the most.

**Acceptance:** the worked example runs; every link resolves; the non-goals match §18 word for word,
asserted; the screenshots are current, regenerated by `bin/demo`.
**Est:** 1 d

---

### M11-3 — CHANGELOG and the versioning policy
**Spec:** §18, §13
**Depends on:** nothing

**Deliver** the promise 1.0 actually makes:

- A CHANGELOG covering 0.1.0 through 0.12.0. It currently has two entries and the gem is at 0.3.0 with
  eleven milestones behind it — the reconstruction is real work and is best done while the PRs are still
  readable.
- **The versioning policy, written out**: what is public API and what is not. That list is needed *now*,
  not at 1.0 — it is what tells an early adopter which surfaces are safe to build on and which may still
  move, and it is the list 1.0 will eventually make a promise about. This matters more for this gem than
  most, because several things that look internal are on it:
  - `Guards::Base::REASONS` — a symbol cannot be renamed without breaking host code that branches on it
    (ADR-0015).
  - The partial inventory and its locals (§12 Tier 3, M6b-6).
  - The CSS class contract (§12 Tier 2, M6c-1).
  - `as_json` and its `schema_version` (M5-7).
  - The error taxonomy's ancestry (ADR-0012).
  - `Value::*` attribute sets, and the closed `tone` vocabulary.
  - The event kinds, and the metadata keys each carries.
- What is explicitly **not** covered: command internals, guard branch order beyond the reasons themselves,
  and anything under `Execution::`.
- **And what 0.x means**, stated plainly: these surfaces are documented and deliberate, and a breaking
  change to one gets a minor bump and a CHANGELOG entry rather than a major. That is the honest promise
  before 1.0, and it is the reason to release 0.12.0 rather than 1.0.0 — an adopter who finds `as_json`
  or the partial locals wrong should be able to have them changed.

**Acceptance:** the CHANGELOG covers every released version; the policy names every list above and each
links to where it is defined; a spec asserts each named constant still exists, so the policy cannot
reference something that has been deleted; the 0.x promise is stated where an evaluator will read it.
**Est:** 1 d

---

### M11-4 — RBS in `sig/`
**Spec:** §2, §17
**Depends on:** M11-3

**Deliver** the type signatures `sig/change_requests.rbs` has held a placeholder for since M0 — it
currently declares `VERSION: String` and a comment pointing at the RBS guide.

- Signatures for the **public** surface, which M11-3 has just enumerated: `ChangeRequests` module methods,
  `Configuration`, `Operation` and `Operations`, the command and guard entry points, the error taxonomy,
  `ActorRef`, the presenters and every `Value::*`.
- **Not** the internals. A signature for every private method is a second implementation to maintain, and
  the value is in the boundary.
- Checked in CI with `rbs validate`, and against the suite with `steep` if it is cheap to add — a signature
  nothing checks is a comment with syntax.

**Acceptance:** `rbs validate` passes in CI; every constant the semver policy names has a signature; the
placeholder comment is gone.
**Est:** 1 d

---

### M11-5 — Release 0.12.0
**Spec:** §18
**Depends on:** M11-1, M11-2, M11-3, M11-4

**Deliver** the first release an adopter is meant to install, and the checks that make it safe to offer:

- The full CI matrix green: Rails 8.1, Ruby 4.0, PostgreSQL, plus the generate-on-a-real-app job (M7-7)
  against the **packaged** gem rather than the checkout.
- `rake change_requests:verify` and the whole sweeper set exercised against the generated app.
- The packaging spec's four `app/` pending examples are green, which they become the moment M6 ships — so
  this is where the pending list empties, and where **every** remaining pending example is either resolved
  or justified in writing.
- Version bumped to **0.12.0**, CHANGELOG dated, tag pushed, gem pushed.
  `metadata["rubygems_mfa_required"]` is already set.
- The gem name is already reserved on RubyGems by a placeholder release (§19.8), so this replaces nothing
  an adopter could have installed by accident.
- The README says what 0.12.0 means: feature-complete against §18's cut line, documented, and asking for
  the feedback that 1.0 will be based on.

**Acceptance:** the packaged gem installs into a fresh application and its generators run; no pending
example remains unexplained; the tag and the CHANGELOG agree; the version is 0.12.0 and nothing in the
repository claims 1.0.
**Est:** 0.5 d

---

## 6. Questions

**Two raised, two answered.** One is §17.1's M10 row, now closed.

| ID     | Question                                                                | Answer                                                                                                                                                                                                                                                                                                                                     |
|--------|--------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Q1** | What object does `config.on_event` receive, and what is preloaded (§17.1)? | **The `Event` record, with `change_request` preloaded and nothing else.** The row is already immutable (ADR-0007), complete on its own, and GlobalID-serialisable — so §10's own `deliver_later` example works unchanged. A value object would be a second representation of a row that is safe to hand out as it is, and a payload hash would throw away the associations a mailer needs. `change_request` is preloaded because almost every notification needs it; nothing else is, because most need none of it and every `emit` would pay. |
| **Q2** | What happens when a host's `on_event` raises?                            | **Logged and swallowed.** It runs after commit, so the approval has already happened — re-raising would report a failure that did not occur and, worse, would surface in the caller as though the command had failed. A host that needs delivery guarantees enqueues, which §10 already tells them to do. |

### Changes these answers make to `PLAN.md`

| Section   | Change                                                        | From |
|-----------|----------------------------------------------------------------|------|
| **§10**   | What `on_event` receives, what is preloaded, and what a raise does | Q1, Q2 |
| **§17.1** | The M10 row closes                                             | Q1   |

---

## 7. Estimate

| Milestone | Tickets | Days     |
|-----------|---------|----------|
| M10       | 4       | 2.25     |
| M11       | 5       | 5.5      |
| **Total** | **9**   | **7.75** |

Against §17's 2–3 d + 4–5 d = 6–8 d.

M10 lands where §17 puts it. **M11 runs long on two tickets that are not writing.** The CHANGELOG is a
reconstruction across eleven milestones, and the **versioning policy is the harder half**: this gem's public
surface includes a partial inventory, a CSS class set, a refusal vocabulary and a JSON schema, none of
which look like API until someone changes one and an adopter's page breaks. Writing that list down is the
work; a spec asserting each named thing still exists is what keeps it true.

---

## 8. Open questions for the maintainer

Nothing here blocks ticket work; each is a judgement worth making before the ticket that depends on it.

1. **Should `on_event` be per-kind rather than one hook?** `config.on_event` fires for all fifteen kinds
   and every host will begin by branching on `event.kind`. A `config.on_event(:overridden) { … }` form
   would put the filter in the gem, at the cost of a more complicated setting — and §8.1 already singles
   out one kind as the one worth alerting on.
2. **Does anything retry a failed `on_event`?** M10-3 swallows and logs, which is right for the command's
   integrity and leaves the notification simply lost. The honest alternative is an outbox, which §18 puts
   explicitly out of scope for 1.0 — so the gap should probably be stated in `docs/08` rather than closed.
3. **What triggers 1.0?** M11 ships 0.12.0 and 1.0 waits for real-world experience — which is the right
   call, and leaves the trigger unstated. Worth deciding roughly: a number of adopters, a period without a
   breaking change to the listed surfaces, or simply the first release where nothing in the policy's list
   has moved for two minors. Without some marker, 0.x is a state that is easy to stay in by default.
4. **Does the CHANGELOG reconstruction belong earlier?** M11-3 rebuilds eleven milestones of history at the
   end. Doing it per-milestone from M4 onward would cost almost nothing each time and would remove the
   single largest piece of guesswork from the release.
5. **What is the deprecation policy for a 1.x change?** The semver policy says what is covered; it does not
   say how something covered is removed. Given that `REASONS` "grows monotonically" (ADR-0015) and the
   partial contract is explicitly semver-covered, a one-minor-version deprecation window with a warning is
   probably the answer, and it should be written down before the first thing needs it.
