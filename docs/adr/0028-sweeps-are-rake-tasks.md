# ADR-0028: Sweep with rake tasks, and keep the destructive one off the schedule

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

Three kinds of row do not resolve themselves. A request nobody acted on sits `pending` past its
deadline. A request claimed by a process that then died sits `executing`, which no command will move
([ADR-0022](0022-execution-in-three-transactions.md)). A request whose operation is no longer declared
can never run at all.

Each needs sweeping. The question is what does the sweeping, and how often — which the plan asserted
in three places without ever saying.

## Decision

`ChangeRequests::Maintenance` holds one method per sweep, each a query plus the command that owns its
transition — never a write of its own. The commands hold the locks and emit the events; the sweeps
decide which rows to hand them ([ADR-0016](0016-commands-are-the-only-writers.md)). Each returns the
number of rows it moved.

`lib/tasks/change_requests.rake` exposes one task per sweep, loaded by the engine's own `lib/tasks`
path so a host requires nothing. Nothing rescues: rake exits non-zero when a task raises, so cron's
mail-on-failure is the alarm, and a sweep that moved nothing is not an error.

**Two are documented as cron. The third is not.**

```cron
5 * * * *  cd /app && bin/rails change_requests:expire_stale
6 * * * *  cd /app && bin/rails change_requests:reap_stuck_executions
```

`change_requests:cancel_undeclared` is run by an operator who has looked. A missing declaration is as
likely to be a deploy accident — an initializer that did not load, a file renamed — as a deliberate
removal, and `canceled` is final. The gem's other responses to an undeclared operation are immediate
**and reversible**: every guard but `Comment`, `Cancel` and `Reap` refuses it, and it leaves inboxes
and badges at once. A scheduled sweep would turn a bad deploy into a table of permanently cancelled
requests within the hour, when reverting the deploy would have cost nothing.

Cron rather than a recurring job, because these are time-of-day work with no per-request trigger, and
because a host running headless has no job backend to schedule into. The interval is a recommendation:
`expires_at` and the reaper's `older_than` are the real deadlines, and a sweeper running late moves the
same rows, just later.

## Consequences

### Positive

- The sweeps are ordinary commands, so every row they move gets its lock, its event and its `System`
  actor for free, and the reaper's transition is guarded like every other one.
- A host with no job backend can still run all three.
- The destructive one cannot fire on its own. Recovering from a failed initializer is reverting the
  deploy, not restoring rows.

### Negative

- **Nothing runs by default.** A host that installs the gem and never reads `docs/05` accumulates
  expired-but-`pending` requests and stuck `executing` rows indefinitely, and nothing warns them.
- Three tasks to schedule is three chances to schedule none.
- `cancel_undeclared` being manual means a stranded request is cleared by whoever notices, which in
  practice is nobody until someone reads a list. §5.11 mitigates this by making such requests
  cancelable by *any* actor, so clearing one does not wait on the rake task — but the bulk path is
  still a decision somebody has to make.
- The reaper's default threshold is a guess about the host's slowest target, and the failure mode is
  silent: an execution written off while it is still working leaves a `failed` row and a side effect
  that lands afterwards.
