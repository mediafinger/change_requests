# ADR-0022: Split execution into three transactions, and commit the claim before the side effect

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

Executing a change request means invoking host code that the gem knows nothing about. It may take
seconds, call an external API, or die halfway through when the box is replaced.

Two requirements pull against each other. A request must never execute twice — that is the whole
promise of the approval gate, and a double charge is worse than no charge. And no row lock may be
held while the target runs, because a lock held across an outbound call blocks every reader of that
request for as long as the call takes, which on a bad day is the socket timeout.

The obvious shape — wrap guard, invoke and record in one `with_lock` — satisfies the first and
violates the second. It also loses the failure: if the target raises, the transaction rolls back and
takes the record of the failure with it, so the row looks untouched and nobody knows an attempt
happened.

## Decision

Three transactions, driven by `Execution::Runner`:

```
T1  with_lock   guard, claim the row, write the attempt, emit execution_started, COMMIT
T2  no lock     invoke the target
T3  with_lock   record the outcome on the request and the attempt, emit its event
```

- **The claim is committed before the side effect runs.** That is what makes this stronger than one
  lock around all three: between T1 and T3 the request is `executing` to every other process and to
  the UI, and a second executor is refused by the guard rather than by luck.
- **T1's conditional `UPDATE … WHERE status IN ('approved','failed')`** is the invariant beneath the
  guard. Zero rows means somebody else holds the claim, and nothing is invoked. With the guard inside
  the same lock the ordinary race never reaches it — the loser is refused `:executing` first — so the
  UPDATE is defence for the paths that skip the guard, not the primary mechanism.
- **The unique index on `(change_request_id, number)` is the claim's second lock.** Two processes
  cannot both write attempt 3, whatever either believes about the status column.
- **T3's failure branch is its own transaction**, so a target that raises leaves no business change
  and a durable record of the failure: `error_class`, `error_message` and a bounded backtrace on the
  attempt, and an `execution_failed` event. The error is then re-raised as `TargetFailed` from inside
  the rescue, so `#cause` is the target's own.
- Each transaction is a command ([ADR-0016](0016-commands-are-the-only-writers.md)):
  `ClaimExecution` and `SettleExecution`, internal in the way `EvaluateWorkflow` is. The runner
  orchestrates and writes nothing itself.

## Consequences

### Positive

- No lock is held across I/O, and that is measured rather than assumed: a `FOR UPDATE NOWAIT` attempt
  while the target is blocked in T2 succeeds, and the same probe against a runner that collapses the
  three into one lock fails. The control is what makes the measurement mean anything.
- A failed execution is fully recorded — which attempt, what raised, and when — while the business
  change it attempted is absent.
- `executing` is a real, visible state, so the UI can show a request mid-flight instead of guessing
  from the absence of an outcome.
- Because T1 commits on its own, background mode is a small change rather than a different design:
  only T2 and T3 move ([ADR-0027](0027-activejob-is-optional.md)).

### Negative

- **A process that dies between T1 and T3 strands the row in `executing`**, which no command will
  move. That is the direct cost of committing the claim, and it is why
  `Maintenance.reap_stuck_executions!` and `Guards::Reap` exist at all
  ([ADR-0028](0028-sweeps-are-rake-tasks.md)). A crash-free design would have been simpler and would
  have executed twice.
- The reaper's threshold is a guess about the host's slowest target. Set shorter than a legitimate
  run, it writes off an execution that is still working: the row goes to `failed` while the target
  keeps going, and nothing recalls it.
- Three transactions mean three chances to fail, and the second and third are not covered by the
  first's rollback. A `SettleExecution` that cannot write is a stuck row the reaper later mislabels
  as abandoned.
- `executing` is the one status no other command will move — `Cancel` refuses it — so the reaper is
  the only way out, and a request whose declaration vanished while executing needed a third
  exemption from the undeclared refusal to stay reachable at all.
