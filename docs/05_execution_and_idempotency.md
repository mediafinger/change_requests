# Execution and idempotency

A change request defers an action. This is what happens when someone finally executes it, what the
gem promises about running it twice, and what has to be swept up afterwards.

## The target contract

A change-request target is a **public singleton method** taking **keyword arguments only**, whose
effect is **idempotent** — running it twice with the same payload leaves the same result as running
it once.

```ruby
class Members::UpdateRoles
  def self.call(member_id:, roles:, change_request_id: nil)
    Member.find(member_id).update!(roles: roles)
  end
end
```

There is no flag to declare otherwise. A failed request keeps its approval and may be retried up to
`op.max_attempts`, so a target that cannot meet the requirement leaves that at `1` and gets one
attempt — the retry ceiling is the only bound the gem can actually enforce.

A target declaring `change_request_id:` receives it, **stable across every attempt**. A target
calling an external API can hand that over as the API's own idempotency key, so a provider that saw
a timed-out first call recognises the retry instead of charging twice. A per-attempt token would
defeat exactly that.

`rake change_requests:verify` checks the half of this that is checkable: every declared service
resolves, answers the singleton method dispatch will call, and takes keyword arguments only.
Idempotence it cannot check, and does not try.

## Three transactions

Execution must never happen twice, and no row lock may be held while the target runs — an external
call can take seconds, and a lock held across it blocks every other reader of that request.

```
T1  with_lock   guard, claim the row, write the attempt, emit execution_started, COMMIT
T2  no lock     invoke the target
T3  with_lock   record the outcome on the request and the attempt, emit its event
```

The claim is **committed before the side effect runs**, which is what makes this stronger than one
lock around all three. Between T1 and T3 the request is visibly `executing` to every other process
and to the UI, and a second executor is refused.

T1's `UPDATE … WHERE status IN ('approved','failed')` is the invariant beneath the guard: zero rows
means somebody else holds the claim, and nothing is invoked. The unique index on
`(change_request_id, number)` is its second lock — two processes cannot both write attempt 3.

T3's failure branch is its own transaction, so a target that raises leaves **no business change and
a durable record of the failure**: `error_class`, `error_message` and a bounded backtrace on the
attempt, and an `execution_failed` event carrying the message.

## Inline and background

```ruby
config.execution_mode = :inline      # default
config.execution_mode = :background  # T2 and T3 run in ChangeRequests::Execution::Job
config.job_class      = "ChangeRequests::Execution::Job"
config.job_queue      = :default
```

T1 commits synchronously in both modes, so the request shows `executing` the moment the call
returns and the UI never has to guess. Only the invocation and its outcome move to the job.

`ChangeRequests::Execution::Job` is defined **only where ActiveJob is loaded**. The gem has no
ActiveJob dependency, so a headless process may have `:background` configured and no job at all:
it boots, `validate!` passes, and `ChangeRequests.background_available?` answers `false`. The
failure arrives when something tries to enqueue, naming ActiveJob.

## Keeping the tables tidy

Three sweeps, none of which happens on its own. Each reports how many rows it moved and exits
non-zero only on error.

| Task | Moves | Why it is not automatic |
|------|-------|--------------------------|
| `change_requests:expire_stale` | `pending` / `approved` past `expires_at` → `expired` | nothing to decide; put it on cron |
| `change_requests:reap_stuck_executions` | `executing` whose attempt nobody settled → `failed`, attempt `abandoned` | nothing to decide; put it on cron |
| `change_requests:cancel_undeclared` | open requests whose operation is no longer declared → `canceled` | **run it by hand** — see below |

### The crontab

```cron
5 * * * *  cd /app && bin/rails change_requests:expire_stale
6 * * * *  cd /app && bin/rails change_requests:reap_stuck_executions
```

Five past rather than on the hour, so they do not land with every other hourly job in the estate,
and a minute apart so they do not contend with each other.

**The interval is a recommendation, not a requirement.** `expires_at` and the reaper's `older_than`
are the real deadlines; a sweeper running late moves the same rows, just later. Run them every ten
minutes if your requests are short-lived, or nightly if they are not.

The reaper's threshold defaults to one hour and takes an override:

```bash
bin/rails change_requests:reap_stuck_executions OLDER_THAN=600
```

Set it comfortably longer than your slowest target. A threshold shorter than a legitimate run will
write off an execution that is still working — the row goes to `failed` while the target keeps
going, and nothing recalls it.

### Why `cancel_undeclared` is not on that crontab

A request whose `operation_key` is no longer declared can never execute, and the gem already treats
it as finished: every guard but `Comment`, `Cancel` and `Reap` refuses it, and it disappears from
inboxes and badges immediately.

Both of those are **immediate and reversible**. Cancelling is neither — `canceled` is final. And a
missing declaration is as likely to be a deploy accident, an initializer that did not load or a file
renamed, as a deliberate removal. A scheduled sweep would turn a bad deploy into a table of
permanently cancelled requests within the hour.

So it runs when an operator has looked and decided:

```bash
bin/rails change_requests:cancel_undeclared
```

If the declaration vanished by mistake, revert the change instead and the requests carry on from
where they were, with nothing lost.

To retire an operation that still has live requests, deprecate rather than delete: keep the
declaration, stop creating requests against it, and let the outstanding ones drain.
