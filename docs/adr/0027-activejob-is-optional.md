# ADR-0027: Make background execution a setting and ActiveJob an optional dependency

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

A target that calls an external API should not run in the request cycle. §8 therefore offers
`config.execution_mode = :background`, moving the invocation and its outcome into an ActiveJob job.

[ADR-0001](0001-headless-domain-core.md) says the domain core must load and run with no Rails at all —
from a job, a console, an API or a rake task. ActiveJob is a Rails framework. Adding it as a runtime
dependency to support an optional mode would make every headless adopter carry it, and
[ADR-0014](0014-executable-architecture-rules.md) forbids the domain from naming the constant at all.

## Decision

`execution_mode` is an ordinary setting, and ActiveJob is not a dependency.

- `ChangeRequests::Execution::Job` lives in a file Zeitwerk **ignores**, required by
  `ChangeRequests.load_execution_job!` on the same terms `load_engine!` already established:
  idempotent, public, guarded by `defined?(::ActiveJob::Base)`. Requiring it without ActiveJob defines
  nothing at all. The engine hooks `ActiveSupport.on_load(:active_job)`, so a host never calls it.
- **T1 commits synchronously in both modes**, so the request shows `executing` the moment the call
  returns and the UI never has to guess. Only T2 and T3 move
  ([ADR-0022](0022-execution-in-three-transactions.md)).
- The job takes two ids, not two objects — a job argument has to survive serialisation. It can settle
  a claim it never made because the executer's triple was recorded on the attempt at claim time.
- `validate!` deliberately does **not** check that `job_class` resolves. A headless process may have
  `:background` configured and no ActiveJob, and refusing that would fail a boot that works.
  `ChangeRequests.background_available?` answers the question, and the enqueue reports it, naming
  ActiveJob.
- `config.job_class` is a string, resolved at enqueue time and never held: a reloading application
  redefines it.

## Consequences

### Positive

- A headless adopter carries no ActiveJob and loses nothing they were using. That is asserted in a
  subprocess: `:background` configured, `validate!` true, `background_available?` false, and a clear
  refusal on enqueue.
- The UI shows `executing` immediately in both modes, so background is a deployment choice rather than
  a different user experience.
- Nothing in the domain names `ActiveJob`, except two `archspec:disable` lines carrying the reason.

### Negative

- A file Zeitwerk ignores is a file the eager-load check does not cover, so a constant misplaced in
  `execution/job.rb` fails at a host's first enqueue rather than in this gem's suite.
- The "is it available" question has three answers depending on when it is asked — at require time,
  after `on_load`, and at enqueue — and only the last is authoritative.
- `execution_mode = :background` is valid in a process that can never perform it. That is the price of
  not failing a headless boot, and it means the misconfiguration surfaces at the first execution
  rather than at deploy.
