# Plan M2 / M3 — operations completed, and execution

Tickets for **M2** (operations, completed), **M3a** (`Commands::Execute` and claim-then-invoke) and
**M3b** (background execution, sweepers, rake tasks), written against `PLAN.md` and against what M1
actually shipped rather than what it was planned to ship.

`PLAN.md` stays the source of truth. Where this document disagrees with it, that is a question in §7, not a
decision already taken.

---

## 1. Scope

| Milestone | Version | What it is                                                                                   | Spec              |
|-----------|---------|----------------------------------------------------------------------------------------------|-------------------|
| **M2**    | 0.3.0   | `op.workflow`, `op.cooldown`, `op.override`, `verify!`, `ChangeRequests.request!`, rake task | §6.4, §6.9, §6.12 |
| **M3a**   |         | `Commands::Execute`, claim-then-invoke, attempts, retry ceiling, the §8.1 override branch    | §8, §8.1, §15.3   |
| **M3b**   | 0.4.0   | Background job, stuck-execution reaper, expiry sweeper, `cancel_undeclared!`, rake tasks     | §8, §5.11         |

**Not here.** Presenters and `as_json` (M5), the UI (M6), generators (M7), the host test kit (M8), the
multi-quorum linking rules (M9a) and cooldown's window (M9b), notifications (M10).

---

## 2. What M1 left standing

Worth stating precisely, because three of these change what the M2/M3 tickets have to do.

**Already built and usable:**

- `ChangeRequests.operations` with `define` / `[]` / `keys` / `each` / `clear`, and `Operation` carrying
  `key`, `version`, `service`, `method_name`, `payload_labels`, `idempotent`, `max_attempts`, `expires_in`.
- `op.approvals`, the §6.4 shorthand, producing a `Workflow` description — `Workflow::Stage`,
  `Workflow::Quorum`, `Workflow::Permission`, all public `Data` value objects.
- `Commands::Create` materialising that description into rows, and refusing an operation that declares no
  `service` or no approvals.
- All seven guards, all eight commands **except `Execute`**, and `Commands::EvaluateWorkflow` including
  `any_quorum` **and** `all_quorums` satisfaction.
- `Guards::Execute` in full: `:already_finalized`, `:not_approved`, `:attempts_exhausted`,
  `may_execute`, and both separation-of-duties settings.
- `Request#retryable?`, the `Attempt` model and its table, the whole error taxonomy, the locale file, and
  `Testing.in_parallel` for concurrency specs.

**Declared but read by nothing** — each is a ticket below, not an oversight to rediscover:

| Surface                                                                     | Declared in                          | Consumed by                                   |
|-----------------------------------------------------------------------------|--------------------------------------|-----------------------------------------------|
| `op.idempotent`                                                             | `Operation`, defaults `false`        | **removed by M2-0** (Q3)                      |
| `config.execution_mode`, `job_class`, `job_queue`                           | §10 only; **not on `Configuration`** | M3b-1                                         |
| `op.cooldown`                                                               | §6.4, §7.1                           | M9b — `Operation` has no such attribute yet   |
| `op.override`                                                               | §6.10, §8.1                          | M3a-5 — `Operation` has no such attribute yet |
| `quorum_not_met`, `override_not_permitted`, `transition_error`              | `errors.rb`, `config/locales/en.yml` | M3a — exempted by name in the locale spec     |
| `execution_started`, `executed`, `execution_failed`, `overridden`, `reaped` | `Event::KINDS`                       | M3a / M3b                                     |

**Three forward commitments left in code comments**, which these milestones either honour or move:

1. `Guards::Approve#countable_quorums` returns every eligible quorum; M9a makes it the lowest-position one
   under `all_quorums`. **M2 ships the DSL that makes such a stage declarable** — see **Q1**.
2. `Commands::EvaluateWorkflow` emits one `quorum_satisfied` per satisfied quorum; M9a owns the per-quorum
   timing detail.
3. `Stage#rejected_at` exists and nothing writes it; M9b owns it with `CloseStageJob`.

---

## 3. Build order

```
M2-0  remove op.idempotent          (independent; before M3a-2)

M2-1  op.workflow DSL ─→ M2-2  remove op.approvals ─┬─→ M2-3 verify! ─→ M2-4 request! ─→ M2-5 rake task
                                                   └─→ M2-6 §6.9 shapes end-to-end

M3a-1 Dispatcher ─→ M3a-2 Runner (T1/T2/T3) ─→ M3a-3 Commands::Execute ─→ M3a-4 concurrency
                                                                        └→ M3a-5 override

M3b-1 execution_mode + Job ─→ M3b-2 Maintenance ─→ M3b-3 rake tasks
```

M3a-1 and M3a-2 are the only pair that must be sequential; everything else in M3a can be written against a
stubbed dispatcher.

---

## 4. Tickets — M2: operations, completed

### M2-0 — Remove `op.idempotent`
**Spec:** §6.4, §8 — **both need amending**
**Depends on:** nothing

**Answered by Q3.** The flag is declared on `Operation`, defaults `false`, and is read by nothing. Rather
than wiring it into `retryable?`, it goes: **every operation must execute idempotently**, and the README
says so.

- Remove the attribute, its default and its spec coverage from `Operation`.
- `PLAN.md` §6.4's example drops the `op.idempotent = true` line; §8's `retryable?` definition becomes
  `failed? && attempts.count < max_attempts`, which is what `Request#retryable?` combined with
  `Guards::Execute` already does.
- README gains the requirement, beside §6.12's existing target contract — which already says the effect
  must be "either transactional or idempotent". This narrows that to idempotent, full stop.

Doing it first means M3a-2 inherits a `retryable?` that already matches the spec, instead of the spec being
amended around code that shipped.

**Acceptance:** no reference to `idempotent` survives in `lib/`; §6.4 and §8 read correctly; the README
states the requirement.
**Est:** 0.25 d

---

### M2-1 — `op.workflow`, the full block DSL
**Spec:** §6.9, §5.2, §5.3
**Depends on:** M1b-0 ✅, M1b-4 ✅

**Deliver** the block form that produces the same `Workflow` description `op.approvals` already produces:

```ruby
op.workflow do |w|
  w.stage :operational, satisfied_by: :all_quorums do |q|
    q.quorum :admin,  permissions: [{ actor_type: "Admin" }], threshold: 1
    q.quorum :owners, permissions: %w(owner), threshold: 2
  end

  w.stage :director, permissions: %w(director), threshold: 1
end
```

- `w.stage name, satisfied_by:` with a block of `q.quorum name, permissions:/actor_type:/eligible_actors:/match:/threshold:`,
  and without a block as the single-quorum shorthand (`w.stage :director, permissions:, threshold:`).
- Stage `position` from declaration order; quorum `position` likewise. Names are snake_case identifiers
  (§5.9), and a named quorum is what `stage_satisfied` metadata reports.
- **It builds a description and nothing else.** `Commands::Create` already materialises whatever it is
  given, and M1b-4's specs already prove a hand-built multi-stage description writes the right rows — so
  this ticket adds a producer, not a second materialiser.
- Declaration-time refusals, matching `op.approvals` (M1b-0): a quorum nobody qualifies for, a threshold
  below one, an unknown `match`, and now also a duplicate stage or quorum name within its parent, which the
  database would otherwise refuse at creation.
- **`threshold:` everywhere, never `required:`.** `op.approvals` spelled the same idea `required:`; that
  drift is part of why it goes (M2-2).
- `q.quorum` keeps `actor_type:` as a top-level keyword alongside §6.9's `permissions: [{ actor_type: … }]`
  hash form, so "any Admin" stays one line rather than becoming a hash literal.

**`all_quorums` ships declarable and knowingly incomplete** (**Q1**). Nothing is released yet, so M9a keeps
the linking rule and M2 lives with a known gap rather than reordering seven milestones or teaching `verify!`
to refuse a shape the docs describe. What that costs, precisely: `Guards::Approve#countable_quorums` links
an approval to *every* quorum it qualifies for, so one person holding both `admin` and `owner` closes both
quorums of §6.9's shape (b) — the shape whose own prose says "this really is three people".

The gap must be **visible in the suite, not just in this document**. M2-6 carries the tripwire.

**Acceptance:** each of §6.9's four shapes (a)–(d) declares, and the description it produces materialises
into the exact row graph the section describes; the shorthand and the block form produce identical
descriptions for the same policy; duplicate names refuse at declaration.
**Est:** 1 d

---

### M2-2 — Remove `op.approvals`
**Spec:** §6.4 — **needs rewriting**
**Depends on:** M2-1

**Answered by Q2.** `op.approvals` is exactly the one-stage shorthand, and once `op.workflow` exists it is a
second way to say the same thing — with a different spelling for the same concept (`required:` against
`threshold:`). Two APIs over one `@workflow` slot is where the silent-overwrite problem came from, and
where the next spelling drift would come from too. It goes.

```ruby
op.approvals permissions: %w(member_admin), required: 2

op.workflow do |w|                                                        # the only way
  w.stage :approval, permissions: %w(member_admin), threshold: 2
end
```

- Delete `Operation#approvals`, `DEFAULT_STAGE_NAME`, and the private `build_quorum` /
  `permission_rows` helpers it owns — or rather, move them, since `op.workflow`'s quorum builder needs the
  identical normalisation.
- **The host now names every stage.** The gem creates no stage called `approval` any more, so
  `config/locales/en.yml`'s `stages.approval` entry loses its only producer. Drop it and keep the comment
  block showing a host how to add their own; the `humanize` fallback already covers every unlisted name.
  M1b-13's `refusal_spec.rb` asserts that entry through `DEFAULT_STAGE_NAME` and changes with it.
- **Migrate the suite:** 24 spec files, roughly 60 declaration sites. Mechanical, but it is the bulk of this
  ticket and the reason it is separate from M2-1 — a large uniform diff is easier to review on its own than
  mixed into new behaviour.
- `PLAN.md` §6.4 is rewritten around `op.workflow`; its four shorthand forms become the single-quorum stage
  form. **`Plan_M1.md` is left alone** — it records what M1b-0 actually built, and that is still true.

**Acceptance:** no reference to `approvals` as a declaration survives in `lib/` or `spec/`; every existing
spec passes on the rewritten declarations; §6.4 reads correctly.
**Est:** 1 d

---

### M2-3 — `Operations#verify!` and `Operation#problems`
**Spec:** §6.12 point 6, §5.10
**Depends on:** M2-1

**Deliver** boot-time verification over the whole registry:

- every operation declares a `version` (already enforced at declaration by M1b-0 — `verify!` re-checks so
  one call reports everything)
- every `service` constant resolves, and the **singleton method** dispatch will actually call exists —
  §6.12: "Verification checks the *singleton* method that dispatch will actually call, so an ordinary
  `def self.call` target is validated against how it is invoked"
- every quorum declares a positive threshold
- no `all_quorums` stage is unsatisfiable
- no `cooldown` is declared without ActiveJob
- **plus what `Commands::Create` already refuses at runtime** — a missing `service`, and no approvals at all
  (M1b-4, Q19). Those checks live on `Operation#problems`, and `Create` calls the same method, so boot-time
  and creation-time cannot disagree.

`#problems` returns an array of human-readable strings, as `Configuration#problems` does; `verify!` raises
one `ConfigurationError` listing all of them (**Q4** — same shape as `validate!`, deliberately: a host that
has seen one of these has seen both). §17.1's open item is closed by that answer.

**Note:** §7's closing paragraph says `Operation#requestable_by?(actor)` "ships with M6a" and "must read the
*same* implementation of the three checks that `Commands::Create` reads — the completeness half belongs on
`Operation` beside `#problems`". This ticket is where that half is created, so M6a has something to read.

**Acceptance:** a registry with four different problems raises once, listing four; a `def self.call` target
verifies and an instance-method-only target does not; `Commands::Create` and `verify!` refuse the same
incomplete declaration with the same words.
**Est:** 0.75 d

---

### M2-4 — `ChangeRequests.request!`
**Spec:** §6.5, §6.12
**Depends on:** M2-3

**Deliver** the host-facing entry point that §6.5 documents, wrapping `Commands::Create`:

```ruby
ChangeRequests.request!("members.update_roles", payload:, requester:, tenant: nil)
```

Positional key, keyword rest — deliberately not `Commands::Create`'s all-keyword shape, because §6.5 is what
every host writes and it reads better. It returns the request and raises the same errors `Create` does:
`UnknownOperation`, `ConfigurationError`, `InvalidPayload`, `NotAuthorized`, `UnknownActorType`.

**Acceptance:** §6.5's example runs verbatim; the error taxonomy is unchanged from `Create`'s; a spec
asserts the two entry points produce identical rows for identical input.
**Est:** 0.25 d

---

### M2-5 — `rake change_requests:verify` and the `to_prepare` hook
**Spec:** §6.12 point 6
**Depends on:** M2-3

**Deliver** the rake task, plus the development/test `to_prepare` hook §6.12 names. The task loads the
host's environment, calls `verify!`, and exits non-zero on failure so CI can run it.

**The hook is the part that needs care.** It runs on every reload in development, and `verify!`
constantizes every declared service — which in a reloading application means holding references to
classes that are about to be redefined. Register it inside the engine only, and re-read the registry each
time rather than memoising.

**Acceptance:** the task exits 0 on a sound registry and non-zero on an unsound one, printing the problems;
a subprocess spec proves it works in the dummy app; the hook does not hold a stale class reference across a
reload.
**Est:** 0.5 d

---

### M2-6 — The four §6.9 shapes, end to end
**Spec:** §6.9, §15.2
**Depends on:** M2-1, M1b-12 ✅

§15.2 asks for "each of the four §6.9 shapes end-to-end, since those are the examples in the docs and must
not rot". Declare each, create a request against it, approve through it with the actors the section names,
and assert the status at every step — including §6.9's worked sequence where a stage-three director is
refused `:stage_not_current` on a stage-one request.

**Shape (b) is the known gap, and this ticket is where it is made visible** (**Q1**). "One Admin AND two
Owners" is `all_quorums`, and its own prose says "this really is three people" — but an Admin who also holds
`owner` closes both quorums with one approval, because `countable_quorums` links to every eligible quorum
(M1b-5, deferred to M9a).

So shape (b) gets **two** specs (**Q10**):

1. **Three distinct people satisfy it** — correct today and after M9a, and the assertion that matters.
2. **One person holding both roles must not satisfy it** — written as `pending`, with M9a named as the
   reason. It reads as "not written yet" rather than "wrong on purpose", and RSpec turns it red the moment
   M9a makes it pass, which is the announcement wanted either way.

That is the same mechanism the suite already uses for the four packaging placeholders waiting on M6.

**Acceptance:** all four shapes, each asserted at every step of its own worked example; shape (b)'s second
spec is pending and names M9a.
**Est:** 0.75 d

---

## 5. Tickets — M3a: execution

### M3a-1 — `Execution::Dispatcher`
**Spec:** §6.12 points 1–2, §8
**Depends on:** M2-3

**Deliver** the allowlist dispatch:

```ruby
Dispatcher.call(operation_key:, payload:, change_request_id:)
```

- Resolves `operation_key → (service, method_name)` **from the live declaration, never from the row's
  columns** (§6.12 point 1). Those columns are audit data. An undeclared key raises `UnknownOperation`
  before anything is constantized.
- Dispatches as `**payload.symbolize_keys` — top-level only, because that is what round-trips through
  `jsonb` (§6.12).
- Passes `change_request_id:` **only when the target declares that keyword**, checked by
  `parameters`, so a target that does not want it is not broken by receiving it.
- The target contract, asserted: a public singleton method taking keyword arguments only.

**Acceptance:** a stored `service` that disagrees with the declaration dispatches to the *declaration*; an
undeclared key raises without constantizing; a target with and without `change_request_id:` both work; a
target taking positional arguments fails with a message naming the contract.
**Est:** 0.75 d

---

### M3a-2 — `Execution::Runner` — the three transactions
**Spec:** §8
**Depends on:** M3a-1

**Deliver** §8's T1/T2/T3 split, which is the whole double-execution fix:

```
T1  with_lock:  Guards::Execute.check!
                conditional UPDATE … WHERE status IN ('approved','failed')
                Attempt(number: attempts.count + 1)
                emit(:execution_started)
                COMMIT                      ← the claim is visible to every other process
T2  no lock:    Dispatcher.call(…)          ← may take seconds; holds no row lock
T3  with_lock:  success → executed_at, executer, status=successful, attempt succeeded, emit(:executed)
                failure → status=failed, attempt failed + error class/message, emit(:execution_failed)
```

- **Zero rows updated by T1 means another process claimed it** — raise `ExecutionInProgress`, do not
  invoke. This is stronger than `with_lock` alone because the claim is *committed* before the side effect.
- The unique index on `(change_request_id, number)` is the claim's second lock.
- **T3's failure branch is recorded outside the rolled-back transaction**, so a target that raises leaves no
  business change and a durable record of the failure.
- `executer` is the acting actor's triple; `Attempt` already has the columns.

**`Request#retryable?` needs no change** (**Q3**). M2-0 removes `op.idempotent` rather than wiring it in, so
§8's definition becomes `failed? && attempts.count < max_attempts` — which is exactly `Request#retryable?`
combined with the `failed?` that `Guards::Execute` already supplies. The retry ceiling is the only limit,
and idempotence is a requirement on the host's target rather than a flag the gem branches on.

**Acceptance:** a successful run writes one attempt, `executed_at`, `successful`, and two events; a raising
target leaves the business change absent and the failure recorded; a second process meeting a claimed
request raises `ExecutionInProgress` without invoking the target; no row lock is held across T2 — asserted
the way M1b-15 asserts serialisation, by measuring.
**Est:** 1.5 d

---

### M3a-3 — `Commands::Execute`
**Spec:** §7, §8
**Depends on:** M3a-2

**Deliver** the command M1b-11 deliberately left absent (D2), wrapping the runner in the shape every other
command has: `.call(request:, actor:, override: false, reason: nil)`, guard first, `NotExecutable` on
refusal. The two override parameters are accepted here and exercised by M3a-5; `Commands::Override` is the
named entry point a host calls (**Q7**).

**Delete `spec/change_requests/guards/execute_spec.rb`'s "the command that is deliberately missing"
group** — six examples asserting the gap, and the note saying an absence is the one thing a suite cannot
state by staying silent. They were scaffolding for exactly this ticket.

**Acceptance:** the guard's truth table now runs through the command; the absence group is gone; §6.6's
worked example runs end to end.
**Est:** 0.5 d

---

### M3a-4 — Execution concurrency specs
**Spec:** §15.3
**Depends on:** M3a-3

The races M1b-15 deferred, in the same shape: `:concurrent`, truncation, `Testing.in_parallel`, and no
mocks inside threads.

1. Two processes executing the same approved request: exactly one invokes the target, the other gets
   `ExecutionInProgress`.
2. A retry racing the attempt ceiling: `attempts.count` never exceeds `max_attempts`.
3. Execute racing Cancel: the request does not end `canceled` with a committed side effect, nor
   `successful` after a cancellation committed first.

**Teeth, as in M1b-15 (Q50):** measure rather than remove. The claim to assert is that **the target is
invoked exactly once** across both threads — a counter, not a timing window — which is deterministic and
needs no sleep.

**Acceptance:** each race asserted; the target-invocation count is the teeth.
**Est:** 0.75 d

---

### M3a-5 — `Commands::Override` and the override branch
**Spec:** §8.1, §6.10
**Depends on:** M3a-3

**Deliver:**

- **`Commands::Override.call(request:, actor:, reason:)`** (**Q7**), which calls
  `Commands::Execute.call(request:, actor:, override: true, reason:)`. A thin, loudly-named wrapper: §8.1
  wants the exception to look like one, and `Execute.call(…, override: true)` buried in a controller does
  not. It also gives M5's presenter two distinct actions to render — `:execute` and `:execute_override`,
  the second `tone: :danger` and always confirmed — without the presenter branching on a boolean.
- `op.override permissions:, require_reason:` on `Operation` — a new attribute; nothing declares it today.
- `Guards::Execute#override_allowed?`: the operation declares an override, the actor satisfies those
  permissions, a reason is present when `require_reason`, the request is non-final and not already
  `executing`. `config.requester_may_override` (already on `Configuration`, defaults `false`) decides the
  requester.
- T1's conditional UPDATE takes `WHERE status = 'pending'` for an override.
- `overridden_at` on the request, and an `overridden` event **emitted at claim time, inside T1**, carrying
  the shortfall exactly as it stood: `{ approvals_present:, approvals_required:, incomplete_stages:,
  incomplete_quorums: }`. §8.1: "a later approval must not be able to make an override look
  retrospectively unnecessary."
- `OverrideNotPermitted` and its `:override_not_permitted` reason — both already in the taxonomy and the
  locale file, exempted by name in M1b-13's spec. **Remove them from that exemption list here.**

The reason is mandatory when `require_reason`, and follows M1b-7's shape (Q25): checked by the command
after the guard, so someone who may not override at all is not told they merely forgot a sentence.

**Acceptance:** an operation declaring no override refuses; the requester refuses unless the config says
otherwise; a missing reason refuses when required; the shortfall snapshot matches the state at claim time
and is unchanged by an approval landing afterwards; `overridden_at` makes the compliance query one column;
`Commands::Override` and `Execute(override: true)` produce identical rows and events, so the wrapper adds a
name and nothing else.
**Est:** 1 d

---

## 6. Tickets — M3b: background execution and sweepers

### M3b-1 — `config.execution_mode` and `Execution::Job`
**Spec:** §8, §10
**Depends on:** M3a-3

**Deliver:**

- `config.execution_mode` (`:inline` | `:background`, default `:inline`), `config.job_class`,
  `config.job_queue` — **three new `Configuration` attributes**; §10 lists them and the class has none of
  them. `validate!` gains their checks.
- `Execution::Job`, **defined only when ActiveJob is loaded**. The gem has no hard dependency on it, and
  `activejob` is a development dependency for the dummy app only. The domain core must still load headless
  with `execution_mode = :background` configured — a subprocess spec, as M0-7 does for the engine.
- T1 still commits synchronously in background mode, so the UI shows `executing` immediately; T2/T3 run in
  the job.

**Acceptance:** inline is unchanged; background enqueues and the job completes the run; a headless process
with background configured loads and reports ActiveJob absent; `validate!` refuses an unknown mode.
**Est:** 0.75 d

---

### M3b-2 — `ChangeRequests::Maintenance`
**Spec:** §8, §5.11
**Depends on:** M3b-1

**Deliver** the four sweepers as one module:

| Method                                       | What it does                                                                                                                                                               | Uses                                                 |
|----------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------|
| `expire_stale!`                              | `pending`/`approved` past `expires_at` → `expired`                                                                                                                         | `Commands::Expire` ✅, `Request.expired_candidates` ✅ |
| `reap_stuck_executions!(older_than: 1.hour)` | `executing` whose attempt never finished → `failed`, `outcome: abandoned`, `reaped` event carrying the attempt number and how long it was stuck (**Q6**)                   | M3a-2's attempt rows                                 |
| `cancel_undeclared!`                         | non-final requests whose `operation_key` is no longer declared → `canceled`, `operation_undeclared` event carrying the key and the request's creation-time version (§5.11) | `Commands::Cancel`                                   |
| `close_due_stages!`                          | **M9b** — listed for completeness, not built here                                                                                                                          | —                                                    |

`expire_stale!` is the easy one: M1b-10 built both the transition and the scope, and a spec already asserts
the two agree on every status. This is the sweep around them.

Every sweeper's event carries the `System` sentinel — `Commands::Base#emit` already stamps it when `actor`
is nil, and M1b-10 proved that path end to end. `reaped` carries `{ attempt: n, stuck_for: seconds }`
(**Q6**), because "which attempt, and how long before anyone noticed" is what an operator asks first.

**`cancel_undeclared!` follows the Expire pattern** (**Q5**): `Commands::Cancel` gains a system path, with
`actor: nil` meaning `SYSTEM_ACTOR`, rather than a second command or a write outside `emit`.

**An undeclared request is cancelable by anyone** (**Q9**), which resolves the collision underneath that:
`Guards::Base` refuses every guard but `Comment` when the operation is gone (§5.11, I8), and those are
exactly the rows this sweeper exists for. So `Guards::Cancel`:

- gains `exempt_from_undeclared_operation!`, joining `Comment` — Base's branch only fires when the
  operation is nil, so exempting the guard *is* "undeclared does not refuse a cancellation"
- returns `nil` early when `operation.nil?`, skipping the requester-or-approver check, so any actor may
  clear a stranded request
- keeps `:already_finalized` and `:executing` ahead of that: a request that is already over stays over, and
  one mid-flight is still not recallable by a status change

This widens §5.11 from "cancel it with a rake task" to "anyone can clear it, and a rake task does it in
bulk". Worth recording there as a deliberate widening, not an implementation detail.

**Who cancelled decides which event is emitted** (**Q11**). A person cancelling emits `canceled`; the system
cancelling because the declaration is gone emits `operation_undeclared` (§5.11, and the kind `Event::KINDS`
already carries). The two are different facts and a timeline should not have to infer one from the actor
column.

Built the way `Commands::Override` is (Q7) — a distinct intent gets a distinct command class rather than a
flag, because every command in the gem hard-codes its own event kind and a caller-supplied kind would be the
first exception:

```ruby
class CancelUndeclared < Cancel
  def self.call(request:) = new(request:, actor: nil, reason: …).call
end
```

`Commands::Cancel` gains two small seams for it — the event kind, defaulting to `:canceled`, and the
metadata — and nothing else changes. `CancelUndeclared` overrides both: kind `:operation_undeclared`,
metadata carrying the operation key and the request's creation-time version **alongside** `Cancel`'s
existing `status`, since what it was cancelled out of is still worth recording.

It supplies its own reason, so `Cancel`'s mandatory-reason rule holds unchanged rather than growing an
exception. The text comes from a new `change_requests.events.operation_undeclared` locale key with the usual
fallback — the first entry in that namespace, and §5.11 should record that the body is translatable rather
than a hardcoded English sentence.

`Maintenance.cancel_undeclared!` is its only caller. An ordinary actor clearing a stranded request by hand
(Q9) goes through `Commands::Cancel` and emits `canceled`, which is correct: they cancelled it, and their
reason is their own.

**Acceptance:** each sweeper moves exactly the rows it should and none it should not; each emits its event
with the `System` sentinel; a request whose operation reappears before the sweep runs is left alone; an
ordinary actor cancelling an undeclared request emits `canceled` while the sweeper emits
`operation_undeclared`; that event records the key and the request's creation-time version, that being the
version whose disappearance it reports (§5.5); `Commands::Cancel`'s own specs pass unchanged, which is what
proves the seams added nothing to its behaviour.
**Est:** 1 d

---

### M3b-3 — Maintenance rake tasks
**Spec:** §8, §10
**Depends on:** M3b-2

One task per sweeper under `change_requests:`, each loading the environment, reporting how many rows it
moved, and exiting non-zero only on error.

`docs/` gains a scheduling section — these are cron-shaped, not job-shaped, and the plan says so in three
places without ever saying how often. **Hourly at five past** (**Q8**):

```cron
5 * * * *  cd /app && bin/rails change_requests:expire_stale
6 * * * *  cd /app && bin/rails change_requests:reap_stuck_executions
```

**`cancel_undeclared` is not on it.** This ticket originally scheduled it at 7 past, which contradicts
§5.11: the bulk cancellation ships as a rake task *rather than* an automatic sweeper, because a missing
declaration is as likely to be a deploy accident as a deliberate removal and `canceled` is final. A
scheduled sweep would turn a failed initializer into a table of permanently cancelled requests within the
hour. It is documented as an operator's decision, with the revert path beside it.

Five past rather than on the hour, so they do not land with every other hourly job in the estate. The
interval is a recommendation, not a requirement: `expires_at` and `older_than` are the deadlines, and a
sweeper running late moves the same rows, just later.

**Acceptance:** each task runs against the dummy app in a subprocess and reports its count; the documented
crontab is the one the tasks are named for.
**Est:** 0.5 d

---

## 7. Questions

**None open.** Eleven were raised while writing these tickets; all are answered and folded into the tickets
they affect.

| ID      | Question                                                     | Answer                                                                                                                                                                                                                                                        |
|---------|--------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Q1**  | M2 or M9a first?                                             | **M2 first; M9a keeps the linking rule.** Nothing is released, so a known-incomplete `all_quorums` is cheaper than reordering seven milestones. The gap is made visible in M2-6 rather than only in this document.                                             |
| **Q2**  | `op.approvals` and `op.workflow` both writing one slot.      | **Remove `op.approvals` entirely.** It is the one-stage shorthand and nothing more; two APIs over one slot is where the silent overwrite came from, and where `required:` against `threshold:` already drifted. New ticket **M2-2**; §6.4 is rewritten.        |
| **Q3**  | `op.idempotent` is read by nothing.                          | **Remove the flag.** Every operation must execute idempotently, stated in the README. `retryable?` becomes `failed? && attempts.count < max_attempts`, which is what already exists. New ticket **M2-0**; §6.4 and §8 need amending.                            |
| **Q4**  | What `verify!` prints.                                       | **Same as `Configuration#validate!`** — one raised error listing every problem. Closes §17.1's M2 row.                                                                                                                                                        |
| **Q5**  | How `cancel_undeclared!` cancels.                            | **The Expire pattern:** `Commands::Cancel` with `actor: nil` meaning `SYSTEM_ACTOR`.                                                                                                                                                                          |
| **Q6**  | The `reaped` event's actor and body.                         | **Sentinel actor**, metadata carrying the attempt number and how long it was stuck.                                                                                                                                                                           |
| **Q7**  | One `Execute` with flags, or a separate command?             | **Both:** `Commands::Execute` keeps `override:`/`reason:`, and `Commands::Override` is the named wrapper hosts call. M5 then renders two distinct actions without branching on a boolean.                                                                     |
| **Q8**  | Sweeper scheduling.                                          | **Hourly at five past**, documented as a crontab. A recommendation, not a requirement — the deadlines are `expires_at` and `older_than`.                                                                                                                       |
| **Q9**  | `cancel_undeclared!` versus the undeclared refusal.          | **An undeclared request is cancelable by any actor.** `Guards::Cancel` joins `Comment` in the I8 exemption and skips its permission check when the operation is gone. Widens §5.11 from "a rake task clears it" to "anyone can, and a rake task does it in bulk". |
| **Q10** | How shape (b)'s known gap is specced.                        | **A `pending` example** naming M9a. Reads as "not written yet", and RSpec reddens it the moment M9a makes it pass — the same mechanism the packaging placeholders already use.                                                                                 |
| **Q11** | Which event an undeclared cancellation emits.                | **Who cancelled decides.** A person emits `canceled`; the system emits `operation_undeclared`. `Commands::CancelUndeclared < Cancel` overrides the kind and metadata, the way `Commands::Override` wraps `Execute` — a distinct intent gets a distinct class.  |

### Changes these answers make to `PLAN.md`

Five sections need amending, and none of them is a detail the tickets can absorb silently:

| Section | Change | From |
|---------|--------|------|
| **§6.4** | Rewritten around `op.workflow`; the four `op.approvals` forms become single-quorum stage forms; `op.idempotent` drops out of the example | Q2, Q3 |
| **§8** | `retryable?` loses its `operation.idempotent?` conjunct | Q3 |
| **§5.11** | An undeclared request is cancelable by anyone, not only by the rake task; the `operation_undeclared` body is translatable | Q9, Q11 |
| **§17.1** | The M2 row (`verify!` output) and the M2/M9a row are both closed | Q1, Q4 |
| **README** | Gains the idempotence requirement, and the crontab | Q3, Q8 |

---

## 8. Estimate

| Milestone | Tickets | Days      |
|-----------|---------|-----------|
| M2        | 7       | 4.5       |
| M3a       | 5       | 4.5       |
| M3b       | 3       | 2.25      |
| **Total** | **15**  | **11.25** |

Against §17's 2–3 d + 3 d + 2 d = 7–8 d.

Three of the fifteen exist because of answers rather than because the plan foresaw them: **M2-0** deletes
`op.idempotent`, **M2-2** deletes `op.approvals` and migrates 24 spec files onto `op.workflow`, and
**M3a-5** grew a wrapper command. M2-2 is the only one that costs real time, and it buys back a whole API
surface — after it there is exactly one way to declare a workflow, and `required:` against `threshold:`
cannot drift again because only one of them exists.

M3a-2 at 1.5 d is the other gap against §17, which gives all of M3a 3 d without counting the override
branch or the concurrency specs separately. M2-6 is not in §17 at all; §15.2 is where the four shapes are
required.
