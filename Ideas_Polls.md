# Ideas: Polls, Slates and Plug-ins

> **Status: idea, not a commitment.** The record of a design conversation, kept so the reasoning
> survives - including the parts that argue against building it. `§` references point at `PLAN.md`;
> "section N" references point inside this file. Companion to `Ideas_Variants.md`.

## 1. The question

The gem gates a decision: a group of people agree or refuse, and a declared action runs or does not.
A yes/no vote is that shape already. The question is the next step up - a decision **between options**:

> "Italian, Chinese or German for lunch?" - tallied at the end, with a winner chosen by a rule that
> weighs approvals *and* rejections rather than simply taking the largest pile.

## 2. The invariant test

Before costing anything, check which of the gem's load-bearing rules a multi-option vote shares and
which it fights.

| What a vote wants                         | What the gem guarantees                                                                 | Verdict |
|-------------------------------------------|------------------------------------------------------------------------------------------|---------|
| The proposer votes                        | Requester != approver, refused in code, no config escape (§7.2, §10)                      | **Fights** |
| Rejections count toward a result          | "Rejection is a stop, not a count" (§7.1)                                                  | Bends - `only_record_rejections` already exists |
| A winner chosen by a rule                 | "Counting approvals is the only rule. There is no rule column and no expression language" (ADR-0008) | **Fights** |
| The outcome determines what runs          | `payload` is `readonly_after_create`; the invocation is legible from the row (§6.12 pt 2) | **Fights** |
| One vote per person per option            | Unique index `(stage, approver_type, approver_id)` - one decision per actor per request    | Fits     |

### 2.1 The requester invariant decides the scope

Row one is the one with no escape hatch, and it splits the feature cleanly in two:

- **"Which of these three vendors do we sign with?"** The proposer abstains, and that is *correct* -
  it is the four-eyes property doing its job. Serveable, and cheaply.
- **"Where do we eat?"** The proposer votes, nothing executes, no guarded action exists. This is not a
  change request. A gem that bends to fit it stops being an approval gate.

`Ideas_Variants.md` section 3.1 argues that requester != approver is the irreducible guarantee, the one
that makes every other knob safely configurable. Spending it on lunch is a bad trade.

**So: multi-option decisions are in scope where the four-eyes property still applies. Opinion polls are
not, and the distinction is not a matter of degree.** Vendor selection, choosing between competing
remediation plans, allocating a budget between proposals - all in. Lunch is the worked example of what
this gem should decline, and it is worth keeping in the docs *as* that example.

## 3. Three shapes

### 3.1 Shape A - a host pattern, zero gem changes

Create three requests, each carrying one option in its payload and a shared correlation key. Run your
own job to pick a winner and cancel the losers.

Works today, unchanged. What you do not get: atomic creation, any exclusivity between siblings, and the
resolution logic, which you write yourself.

### 3.2 Shape B - mutually exclusive request groups ("slates")

Make that pattern first-class. A `change_request_groups` table and a nullable `group_id`;
`request_slate!` creating N siblings in one transaction; a **registered tally resolver** that picks the
winner at the shared deadline, executes it, and cancels the losers with a reason.

It composes unusually well with what already exists:

- **Every sibling stays an ordinary change request** with a frozen payload. The dispatch allowlist
  ([ADR-0010](docs/adr/0010-operations-must-be-declared.md)), creation-time immutability
  ([ADR-0006](docs/adr/0006-creation-time-immutability.md)) and snapshot-on-create are untouched. This
  is the whole reason the shape is cheap.
- **Approval voting comes free.** The unique index `(change_request_stage_id, approver_type,
  approver_id)` already means one decision per actor per sibling. Approve Italian, reject Chinese,
  abstain on German - three rows, no new table.
- **Rejections already behave like ballots** under `config.only_record_rejections = true` (§7.1): the
  decision is recorded, it does not short-circuit, and the rejector has spent their vote on that stage
  and cannot later approve it. That is ballot semantics, written for a different reason.
- **The winner rule is a registered resolver**, keyed by name, declared in code - the same allowlist
  pattern as `service`/`method_name` and the population queries in `Ideas_Variants.md` section 5.2.
  Net score, quota, weighted, "must beat the runner-up by two": all expressible, none of it as data in
  a database, none of it an expression language. ADR-0008's "no rule column" survives intact.
- **The voting deadline is `expires_at`.** At the deadline the group resolves instead of expiring,
  which rides on the expiry work in `Ideas_Variants.md` section 6.

Costs that are real and should not be buried:

- `EvaluateWorkflow` must **not** promote a grouped request to `approved` when its final stage is
  satisfied - the group decides, later. That is a branch in the one place §7.1 names as the sole owner
  of status transitions. Section 5.4 is about making that branch safe.
- `only_record_rejections` is global config today; a slate needs it per operation.
- True exclusivity - one vote across *all* siblings rather than one per sibling - needs cross-request
  locking in deterministic id order, with the deadlock risk that implies. Approval voting needs none of
  it, which is an argument for shipping approval voting only.

**Roughly 6-9 days.** One milestone.

### 3.3 Shape C - native polls, and why the payload is the wall

Options as rows, ballots referencing options, a `kind` column on the request, a tally engine, ranked
ballots for anything Condorcet-shaped.

The blocker is not the ballot table, it is the payload. `payload` is `NOT NULL` and
`readonly_after_create`, because what a request will invoke has to be legible from the row and fixed
before anyone approves it. A poll inverts that: the outcome *determines* the payload. Two ways out,
both costly:

1. Every option carries a pre-frozen payload fragment and execution reads the winning option through a
   join. Immutability survives; §6.12 point 2 ("legible from the row itself") no longer does.
2. `payload` becomes nullable until close. ADR-0006 goes.

On top of that, `kind` makes every guard, command, scope, presenter and view polymorphic.

**3-5 milestones**, comparable to M1b + M5 + M6 combined, and it roughly doubles the gem's conceptual
surface. §18's non-goals list exists to prevent exactly this.

### 3.4 What shape B does not give you

- **Ranked preference.** One binary decision per sibling yields approval voting and net-score rules.
  Borda, Condorcet and instant-runoff need one ballot row per `(actor, option, rank)` - that is shape C,
  and no amount of cleverness in shape B reaches it.
- **Opinion polls.** A group whose winner executes nothing has no reason to live in this gem.
- **The proposer's vote.** Section 2.1.

## 4. Cost summary

| Shape | What it delivers                                                  | Core changes                         | Effort        |
|-------|--------------------------------------------------------------------|---------------------------------------|---------------|
| A     | Nothing the host cannot already build                              | None                                  | 0             |
| B     | Approval voting between options, tallies, winner executes          | One narrow concession (section 5.4) + additive extension points | 6-9 d |
| C     | Ranked ballots, arbitrary voting systems, opinion polls            | Pervasive; ADR-0006 or §6.12 pt 2 goes | 3-5 milestones |

## 5. Ship it as a plug-in gem

**Shape B should not land in the main code base.** Not because it is unsound, but because of what it
would do to the gem's identity: §18 sells a ninety-second non-goals list, and "approval gate for a
declared action" is a sharper promise than "approval gate, and also a voting system". An adopter
evaluating the gem for four-eyes compliance should not have to read past a polling feature to decide.

A separate `change_requests-polls` gem keeps the cut line intact, lets poll adopters opt in explicitly,
and releases on its own cadence. It also forces something the core benefits from regardless: **a
declared public API**. A gem with no out-of-tree consumer has no idea which of its classes are load
bearing, and finds out the first time it renames one.

### 5.1 What already works with zero core changes

More than expected. A plug-in today can:

- **Own its tables.** [ADR-0009](docs/adr/0009-host-owned-schema.md) has the host run a generated
  migration; a plug-in ships its own generator writing its own migration. The gem never migrates at
  runtime, so there is no ordering problem to solve.
- **Foreign-key into `change_requests`** with `ON DELETE CASCADE`, the same rule ADR-0009 applies
  between core tables. Deleting a request takes the plug-in's rows with it.
- **Declare its own operations** into `ChangeRequests.operations` from the host's initializer.
- **Observe everything.** `config.on_event` fires `after_commit`, and `ActiveSupport::Notifications`
  publishes under `change_requests.<kind>`. A read-only plug-in - analytics, dashboards, notification
  routing - needs *nothing* from this section.
- **Mount its own engine** with its own routes, controllers and views
  ([ADR-0002](docs/adr/0002-mountable-engine-with-isolated-namespace.md)).
- **Inherit from `ChangeRequests::Record`**, which sets `belongs_to_required_by_default` itself
  (§19.19) rather than reading host configuration - so a plug-in's models get the same guarantee
  without depending on the host's Rails settings.

### 5.2 Additive changes the core needs

Each of these is small, is useful to the core on its own merits, and breaks nothing.

| Change | Why | Cost |
|--------|-----|------|
| **A declared public API, under semver.** `Operations`, `Operation`, `Commands::*`, `Guards::Base`, the error taxonomy, `Record`, `Testing`. Everything else explicitly internal. | Without it a plug-in binds to whatever it can reach, and every refactor is a breaking change nobody knew they made. | Docs + one spec asserting the surface. Days, not weeks. |
| **An event-kind registry.** `ChangeRequests.events.register_kind("polls.group_resolved")`. | §19.16 already chose a validation over a CHECK constraint *precisely* so new kinds need no host migration. The affordance exists; only the registration does not. | Hours. |
| **Namespaced operation declaration extensions.** `op.extension(:polls)` returning a bag the plug-in validates, with `validate!` delegating to it. | Plug-ins need declaration attributes (`op.tally`, `op.slate`). The alternative is monkey-patching `Operation`, which is how plug-ins break hosts. Core attributes stay closed; plug-in attributes still fail at boot with the initializer's line number. | Small. |
| **A reusable `Registry` primitive.** | The core already needs one twice - operations, and the population/tally resolvers. Extract once, and plug-ins get the same isolation story the test suite needs. | Refactor, not a feature. |
| **Maintenance sweeper registration with declared ordering.** | A slate must resolve *before* the expiry sweeper runs, or the deadline kills the vote it was supposed to close. Identical in kind to the `close_due_stages!`-before-expiry ordering in `Ideas_Variants.md` section 6.4 - the core needs ordered sweepers anyway. | Small. |

### 5.3 What plug-ins must never do

These are the rules that keep "without breaking any original functionality" true. They belong in the
plug-in author's guide, and a couple can be enforced.

1. **Never add a status.** `change_requests.status` is a CHECK constraint
   ([ADR-0005](docs/adr/0005-string-states-with-check-constraints.md)), so a new one is a migration in
   every host application. Shape B needs none: a losing sibling is `canceled` with a reason, which is
   already a final status with an audit trail. Any plug-in that *needs* a status is asking for a core
   change, not a plug-in.
2. **Never reopen `ChangeRequests::`.** Own `ChangeRequests::Polls::` and its own Zeitwerk root.
   Monkey-patching core classes is the failure mode that makes "plug-in" a synonym for "breaks on
   upgrade".
3. **Never run inside a command's transaction uninvited.** `config.on_event` is `after_commit`
   deliberately: a notification that raises must not roll back an approval. Plug-in hooks inherit that
   rule, or inherit the consequence.
4. **Namespace event kinds** (`polls.group_resolved`), so two plug-ins cannot collide and so a host
   reading the timeline can see where a kind came from.
5. **Declare a core version constraint** and check it at boot. Version skew against a documented surface
   is manageable; version skew against internals is not.
6. **Respect the `lib/` boundary.** Business logic that cannot reach `app/`, exactly as `AGENTS.md`
   requires of the core.

### 5.4 The one concession that is not additive

Everything above is additive. Shape B still needs one thing that is not, and it is worth stating
plainly rather than hiding in a table:

> A grouped request must **not** become `approved` when its final stage is satisfied. The group decides
> the winner afterwards.

That is a change to status-transition logic - the single thing §7.1 reserves to `EvaluateWorkflow`, and
the last place a plug-in should be allowed to reach. Two ways to give it:

- **(a) A callback into `EvaluateWorkflow`.** Rejected. Any plug-in that can veto or defer the
  `approved` transition can break every guarantee the gem sells, and the failure would be silent.
- **(b) A narrow concept owned by the core.** `op.resolution = :immediate | :deferred`. Under
  `:deferred`, stage satisfaction never promotes the request; an explicit command does. The branch
  lives in core, is tested in core, and is one boolean. The plug-in supplies only the command that
  resolves.

**(b), clearly** - and it is the same philosophy as ADR-0010. Do not let outside code drive the
sensitive path; declare a bounded concept and let outside code select it. It also generalises beyond
polls: anything that needs "hold this request open past quorum" uses the same flag, and it is close kin
to `cooldown`, which already keeps a satisfied stage from closing.

Where the flag is stored is the open question. Deriving it live from the operation would let an edited
declaration change an in-flight request, which ADR-0010 point 4 forbids - so it is a column,
`resolution string not null default 'immediate'` with a CHECK, snapshotted at creation like everything
else. See **Q1**.

### 5.5 What happens when a plug-in is removed

Better than expected, and for free. A plug-in's operations stop being declared, and §5.11 already
handles that case: every guard except `Comment` refuses, the requests leave inboxes and badges
immediately, commenting stays open so someone can leave a note, and
`Maintenance.cancel_undeclared!` closes them out deliberately rather than automatically. Reinstalling
the plug-in restores them with no data loss.

The core must never query a plug-in's tables, which is exactly why the `resolution` flag in section 5.4
has to be expressed in core terms. A request whose `group_id` points at a vanished table is then merely
a dangling reference in an audit column, not a broken evaluation path.

### 5.6 The honest cost of having an extension surface

- **A published surface is harder to change than internal code.** Today `Operation` can be refactored
  freely. After, it cannot. That cost is paid forever and is the main argument for keeping the surface
  small.
- **Two repos, two CI matrices, two test kits**, and support questions that arrive as "the polls gem is
  broken" when the answer is a version pair.
- **Extensibility claimed without a consumer is extensibility claimed falsely.** The only way to know
  the surface is real is to build something out-of-tree against it. Which argues that *if* polls are
  ever built, they should be built as the plug-in from day one - not extracted later.

## 6. Open questions

- **Q1 - where does `resolution` live?** A column on `change_requests` (snapshotted, consistent with
  ADR-0006 and ADR-0010 point 4) or derived live from the operation (no migration, but an edited
  declaration reaches in-flight requests). The column is right; the question is whether to add it
  **now**. §17 argues the staged schema was worth building up front because tables are cheap early and
  expensive to retrofit - but §19.11 rejected exactly this kind of speculative flexibility for primary
  keys. Genuinely contested; decide deliberately rather than by habit.
- **Q2 - per-operation `only_record_rejections`.** A slate needs rejections to count rather than stop.
  Today it is global config. Per-operation is small and useful beyond slates - but it means two requests
  in one application treat a rejection differently, which has to be visible in the UI.
- **Q3 - exclusivity.** Ship approval voting only (no cross-request rule, no locking), or enforce one
  vote across the slate? The second needs cross-request locks in deterministic id order. The first is
  a defensible voting system on its own and costs nothing.
- **Q4 - does a slate need a quorum at all?** If the winner is decided at the deadline by tally, the
  per-sibling `threshold` may be meaningless - or may serve as a floor ("no vendor wins on one vote").
  Both are defensible; the second is more useful and needs the tally resolver to see thresholds.
- **Q5 - what executes when nothing wins?** A tie, or every option below its floor. Cancel the whole
  slate, re-open it, or escalate. Needs an answer before the resolver interface is designed.
- **Q6 - is `request_slate!` atomic across N operations?** Siblings could target *different* operations
  ("buy" vs "lease" vs "do nothing"), which is more useful than N payloads of one operation - and makes
  the group, not the request, the unit the presenter renders.

## 7. Recommendation

**Do not build this now.** M1b through M3 are not done; a second decision-making mode in a gem that has
not shipped its first one is the wrong order regardless of how cheap shape B is.

What is worth doing early is **section 5.2's public API surface**, because it pays for itself with no
plug-in in existence: it forces the core to say which classes are load bearing, and that is information
the gem needs before 1.0 pins the answer by accident.

If an adopter ever asks for "choose between these three remediation plans", shape B is designed and
costed here, and the answer to the lunch poll that will also arrive is written down: it is not a change
request, and the reason is in section 2.1.
