# Ideas: Variants and Dynamic Quorums

> **Status: idea, not a commitment.** Nothing here is planned work. It is the record of a design
> conversation so the reasoning survives, including the parts that argue against building it.
> §-references point at `PLAN.md`. Nothing in `PLAN.md` changes until one of these is accepted.

## 1. The problem

Today a developer must ship a code change to alter an approval workflow. Declaring the *dispatch*
target in code is non-negotiable ([ADR-0010](docs/adr/0010-operations-must-be-declared.md)) - only a
developer can answer "which service, which method, which parameters". But the same declaration also
carries the *policy* - thresholds, permissions, stages - and that is the part that changes when
regulation changes, not when code changes.

Two capabilities are wanted:

- **Variants** - an admin-authored deviation from an operation's base workflow: more or fewer
  approvals, different roles, more or fewer stages.
- **Dynamic quorums** - a threshold that is not a literal, but is computed when the request is
  created: "more than 33% of the voting body".
- **Deadlines** - an expiration period, mandatory on every operation, that a variant may shorten or
  lengthen within a declared range.

The motivating case is mundane and is worth keeping in view throughout: a function shrinks, the second
approver leaves, and the organisation needs its approval rule to say so - without waiting on a deploy.
Section 3.1 takes that case seriously, because it determines how the rest of this document is designed.

## 2. What makes this tractable

The registry bundles two unrelated things into one object:

| Concern      | Attributes                                                                                | Must stay code?    |
|--------------|-------------------------------------------------------------------------------------------|--------------------|
| **Dispatch** | `service`, `method_name`                                                                  | **Yes** - ADR-0010 |
| **Policy**   | `workflow`, thresholds, permissions, `max_attempts`, `expires_in`, `cooldown`, `override` | No                 |

Only policy is in scope. And because [ADR-0008](docs/adr/0008-staged-multi-quorum-schema.md) freezes
the resolved workflow into stage and quorum rows at creation, **nothing after `Create` ever reads live
policy again**. Guards, `EvaluateWorkflow`, execution and the presenter all read the snapshot.

> Every table in §5.3 is write-once, materialised when the stage is created from the frozen workflow,
> and never updated.

So both features need to influence exactly one moment: the point in `Commands::Create` between
"resolve the operation" and "materialise the rows". That is the entire integration surface.

**`change_request_quorums.threshold` stays `integer, null: false` with `CHECK threshold >= 1`.** A
dynamic threshold resolves to an integer before it is written. The counting path, the inbox query and
every guard are untouched.

## 3. Invariants that must survive

Anything that breaks one of these is out of scope, not a trade-off to negotiate.

1. **No code in the database, ever.** A lambda stored as a string is `eval` on a row - the exact hole
   ADR-0010 closed for `service`/`method_name`. The payoff is arbitrary code execution in the host
   process. That has nothing to do with approval policy and no envelope bounds it.
2. **`operation_key` keeps meaning "the declared operation".** A variant is *not* a new operation key.
   Variant identity lives in separate, audit-only columns, so the dispatch allowlist and the
   undeclared-operation refusal (§5.11) are unchanged.
3. **Snapshot-on-create is absolute.** A variant edited after a request exists never reaches it.
4. **Policy history is append-only** ([ADR-0007](docs/adr/0007-append-only-audit-trail.md)). Variants
   are versioned, never updated in place. A request pins `(variant_id, variant_version)`.
5. **A quorum a variant produces is reconstructible.** "Why did this request need 5 approvals?" must be
   answerable from the row, years later, without the variant table being intact.
6. **Requester and approver are never the same identity.** Refused outright in code, not a setting
   (§7.2, §10). No variant, envelope or threshold can reach it - which is precisely what makes
   everything above it safely configurable.

### 3.1 What the gate guarantees, and what `threshold: 1` is

**`threshold: 1` is a legitimate configuration, not a bypass.**

Two-person integrity does not come from the threshold. It comes from requester != approver, which is
unconditional code (invariant 6). A one-approval workflow still involves two distinct identities: one
to request, one to approve. The four-eyes property survives `threshold: 1` intact - what shrinks is the
*number of reviewers*, which is a policy question an organisation is entitled to answer for itself.

The one place a single person can act alone is `config.requester_may_override = true` plus an
`op.override` permission - opt-in, reasoned, separately permissioned, and recorded as an exception
(§8.1). That is where scrutiny belongs, and it is already where the plan puts it.

**Design consequence.** The envelope (section 4) exists for legibility and deliberateness, not
prohibition. It records what an operation's policy is *allowed to become*, so that range is reviewed
once in code instead of discovered later from a database. It is not there to stop an organisation
describing itself accurately.

## 4. Off by default, three independent gates

This is a strictly conditional feature. A host that does not opt in must never pay for it - no query,
no table, no branch on the hot path.

### Gate 1 - the feature flag

```ruby
config.variants = false   # default
```

When false, `Create` never touches the variants table and the resolver is not constructed. Not a
performance nicety: it means a host can be certain, by reading one line, that approval policy comes
only from code.

### Gate 2 - the schema is a separate, opt-in migration

`rails g change_requests:variants` writes a second migration. The nine tables of §4 stay as they are;
a host that never enables variants carries no variant schema at all. Consistent with
[ADR-0009](docs/adr/0009-host-owned-schema.md) - the host owns and reviews it like any other migration.

### Gate 3 - per-operation envelope, forbidding by default

**Every operation forbids variants unless it says otherwise.** There is no global "allow all". The flag
is not a boolean but a map declaring *which knobs* may be turned and *within what bounds*:

```ruby
ChangeRequests.operations.define "budget.approve" do |op|
  op.version = "2026-09-11"
  op.service = "Budget::Approve"

  op.workflow do |w|
    w.stage :review,   permissions: %w(controller), threshold: 1
    w.stage :sign_off, permissions: [{ actor_type: "Director" }], threshold: 2
  end

  op.expires_in = 14.days                          # mandatory - section 6.1

  op.allow_variants(
    actors:      [{ actor_type: "Admin" }, { permission: "director" }, { permission: "manager" }],
    quorums:     { review: 1..3, sign_off: 1..5 },   # sign_off may fall to one as the function shrinks
    populations: %i(voting_body directors),
    expires_in:  1.hour..14.days,
    stages:      :fixed
  )
end
```

Semantics, one key at a time:

| Key           | Means                                                                                                                                                |
|---------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `actors`      | The only eligibility rows a variant may write, in the §5.3 2x2 vocabulary (`actor_type` x `permission`). Anything outside is refused at write time.  |
| `quorums`     | Per **stage name** (§5.9 - names are stable, positions are not), the range a threshold may take. A stage absent from the map is not variable at all. |
| `populations` | Which registered population queries (section 5.2) a variant may reference. Absent key = dynamic thresholds forbidden for this operation.             |
| `expires_in`  | The range of durations a variant may set as the expiration period (section 6). Absent key = the deadline is not variable.                            |
| `stages`      | `:fixed` (default) - stage set is immutable. See open question **Q1**.                                                                               |

Three properties worth stating explicitly:

- **Absence is denial.** An unlisted key is not "unconstrained", it is "forbidden". The map is an
  allowlist, like the registry itself.
- **The envelope bounds change, it does not forbid it.** A host that wants `1..3` declares `1..3`, and
  a variant that then sets `1` is the system working as intended (section 3.1). The value is that the
  range is declared in code and reviewed once. CRUD is the easy part; the range is the part worth
  designing.
- **The envelope is code**, so the *limits* on policy stay in git and under review even when the policy
  itself does not. This is what makes the whole idea defensible to an auditor.

## 5. Dynamic quorums

### 5.1 Why named rules were rejected

An earlier sketch proposed a fixed vocabulary - `:majority`, `:two_thirds`, `:all`, `:all_but_one`.
Rejected: real regulation asks for 5%, 20%, 25%, 33%, 66%, and the vocabulary would grow forever while
still never covering the next case.

### 5.2 The shape instead

Four parts. One is code, three are data.

```ruby
# code, in git, written once by a developer
ChangeRequests.populations.define :voting_body do |ctx|
  Admin.count + User.where(role: %w(manager director)).count
end
```

```
population  :voting_body    -> N, an Integer, computed at request creation
ratio       33%             -> a Rational
operator    > or >=         -> how approvals compare to ratio x N
eligibility the quorum's own permission / eligible-actor rows -> who may approve
```

The **basis** is code, because only the host can run that query - [ADR-0003](docs/adr/0003-actor-references-as-triples.md)
guarantees no foreign key will ever point at a host table, so the gem cannot count host records. The
**ratio, operator and clamps are data**, editable by an admin. This is the resolver-by-key pattern that
ADR-0010 already established for dispatch, with a continuous parameter instead of a fixed enum: *the
registry is the allowlist for code, in both cases.*

### 5.3 The arithmetic

Integer and `Rational` only. Never `Float` - `0.1 + 0.2` deciding whether a payment needs one more
signature is not a defensible position.

Given population `N`, ratio `r`, and the minimum number of approvals `n` that satisfies the rule:

```
operator >=    n = (r * N).ceil
operator >     n = (r * N).floor + 1
```

then apply optional `min:` / `max:` clamps, then validate `1 <= n <= N`.

| N  | r   | op   | r x N | n | Note                                 |
|----|-----|------|-------|---|--------------------------------------|
| 9  | 1/2 | `>`  | 4.5   | 5 | the classic majority                 |
| 10 | 1/2 | `>`  | 5     | 6 |                                      |
| 10 | 1/2 | `>=` | 5     | 5 | **the operator earns its keep here** |
| 9  | 1/3 | `>=` | 3     | 3 |                                      |
| 9  | 1/3 | `>`  | 3     | 4 | same inputs, different answer        |
| 10 | 1/3 | `>=` | 3.33  | 4 |                                      |
| 0  | any | any  | 0     | - | **refuse** - see 5.4                 |

**The operator only changes the answer when `r x N` lands exactly on an integer.** That is precisely
when a policy argument happens, which is why it must be explicit and must never be defaulted silently.

`min:` and `max:` exist because "33%, but never fewer than two people" is a real regulatory shape.
They are a floor a host may *choose*, not a safety rail the gem imposes: a ratio over a shrinking body
converging on `1` is the rule working, not failing (section 3.1). Ship the clamps, default them to
absent, and let each host state which behaviour its own regulator asked for.

### 5.4 Failure modes, all of which need a decision

| Case                     | Behaviour                                                                         |
|--------------------------|-----------------------------------------------------------------------------------|
| `N = 0`                  | Refuse at creation. A quorum over an empty body is unsatisfiable, not lenient.    |
| `r = 0`                  | Refuse at declaration. `0%` with `>` silently means "any one person".             |
| computed `n > N`         | Refuse - unsatisfiable, the request would sit pending until it expired.           |
| computed `n < 1`         | Refuse - violates the CHECK constraint anyway.                                    |
| population query raises  | Typed error from `Create`, never a 500.                                           |
| population query is slow | It runs inside `Create`'s transaction. Document the constraint; do not police it. |

Every one of these fires at **request creation**, not at boot. `refuse_threshold` in
`lib/change_requests/operation.rb` currently reports misconfiguration with the initializer's own line
number; dynamic thresholds move that class of failure into a user-facing action. It needs a typed error
in the [ADR-0012](docs/adr/0012-declared-error-taxonomy.md) taxonomy - `UnsatisfiableWorkflow` or
similar - rescued in the controller beside `InvalidPayload`.

### 5.5 The hazard: population and eligibility can disagree

This is the sharpest edge in the whole design.

The population query counts `Admin.count + User.where(role: ...)`. Eligibility is permission rows
`(permission, actor_type)`. **Nothing forces them to describe the same set of people.** A host can
declare "33% of 120" while the eligibility rows admit four people, and the request is unsatisfiable
from birth.

The gem cannot detect this. Per §5.3, eligibility is *only ever* evaluated actor -> request: the inbox
query binds `:actor_permissions` from the host's `t.permissions` lambda for one loaded actor. There is
no enumeration of "everyone holding `director`", and there cannot be one.

So the satisfiability guarantee is asymmetric, and the docs must say so rather than implying uniform
safety:

- **Named-actor quorums** - the gem writes `change_request_quorum_eligible_actors` rows, so it knows the
  population and *can* check `n <= N`.
- **Permission quorums** - unverifiable. Best available mitigations: a `verify!` warning, and a host
  test-kit helper that runs the population query against a sample context.

**Proposed mitigation worth prototyping:** let a population query return *actors* rather than a count.
`Create` then counts them and materialises the eligible-actor rows from the same relation, so the two
agree by construction and satisfiability becomes checkable. Cost: one row per member per request - fine
for a 12-person board, wrong for a 5,000-member body. Offer both, recommend the actor-resolving form
below some size, and accept unverifiability above it.

### 5.6 Provenance is mandatory, not a nicety

A population query reads the database, so it is non-deterministic by design: two identical requests a
minute apart can yield different thresholds, correctly. Without a record, "why did this one need 5 and
that one 4?" is unanswerable - which is the question this gem exists to answer.

One nullable `jsonb` column on `change_request_quorums`:

```json
{ "population": "voting_body", "count": 9, "ratio": "1/3", "operator": ">", "computed": 4,
  "variant": { "id": "...", "version": 3 } }
```

Additive, nullable, `{}` for every statically-declared quorum. This is the only schema change the
counting path needs, and it is what makes invariant 3.5 hold.

### 5.7 Membership changes after creation

Nine members at creation gives a threshold of 5. Two more join. The request still needs 5 - the
threshold was materialised. This is correct: it matches snapshot-on-create, and it matches how quorum
works in every deliberative body (fixed when the motion is tabled). It is also surprising, so the
presenter must show it: **"5 of 9 voting members, as of 11 March"**, not "5 approvals needed". A bare
number is one an approver cannot sanity-check.

## 6. Expiry

### 6.1 Mandatory at declaration

Today `op.expires_in` is optional and falls back to `config.default_expires_in`, which itself defaults
to `nil` - and `lib/change_requests/operation.rb` documents `nil` as "this operation never expires".
The decision here is to make a period **mandatory**: `Operation#problems` grows a second entry beside
the `op.version` check, and an operation declaring no period fails at boot, reported against the
initializer's own line.

The rationale is the one that already makes `op.version` mandatory. An unanswered request is not
neutral - it occupies an inbox, it carries an intent that may no longer be wanted, and it degrades the
queue as a signal for everything else in it. "Forever" should be something a person chose, not
something nobody typed. Open question **Q8** covers whether `:never` stays reachable as an explicit
value.

### 6.2 What a variant may change

`expires_in` is a duration on the declaration; `expires_at` is the timestamp materialised onto the
request at creation. The same declared-vs-resolved split as a threshold, resolved at the same moment.

```ruby
op.expires_in = 14.days

op.allow_variants(
  # ...
  expires_in: 1.hour..14.days,
)
```

The envelope key is a range of durations, and absence means the knob is not variable - the rule
everywhere else in section 4.

**Deliberately not dynamic.** A threshold earns a computed value because it tracks a population that
moves. A deadline does not: it is a policy number, not a measurement. Keep it a literal duration from a
bounded range - no resolver, no population query.

### 6.3 Why this knob behaves differently from a threshold

Section 3.1 argues that a variant lowering a threshold to `1` is an organisation describing itself
accurately. A 24-hour window is equally legitimate: emergency access grants, trading windows and
temporary credentials are all cases where 24 hours is correct and 14 days is negligence.

The difference is not legitimacy, it is **how the outcome is reached**. Every other terminal status
follows from somebody acting - approving, rejecting, cancelling, executing. `expired` is the only one
that arrives because nobody did anything. A shorter window therefore does not make a worse decision
more likely; it makes *no decision* more likely, and no decision is indistinguishable from a missed
notification, a weekend or a public holiday.

The design response is visibility, not restriction:

- `expired` becomes one of the two events most worth wiring to a notification channel on day one,
  beside `overridden` - §8.1 already makes that recommendation for the other.
- The presenter renders the deadline, not only the status, and renders it on the **index row**, where
  an approver sees it without opening anything.
- Reminders before expiry are out of scope for 1.0 (§18 lists escalation and reminders as out). A short
  variant window is the strongest argument yet for revisiting that, and the argument belongs here
  rather than in an issue nobody rereads.
- `min:` in the envelope carries more weight here than it does for thresholds, because the floor
  protects against silence rather than against a decision.

### 6.4 Expiry and cooldown

A stage that has met its quorums but sits inside its cooldown window has `satisfied_at` set and is
**not yet closed** (§7.1); the request is still `pending`. Under the sweeper rule as written - "`pending`
or `approved` past `expires_at`" (§7.2) - that request expires, destroying approvals that were given
and were merely waiting out a reversal window. This is the case the feature has to close.

**Rule: a request is not expirable while its current stage is `satisfied`.** The cooldown runs to
completion, the stage closes, and the request advances or becomes `approved`.

Two consequences to take deliberately:

- **A multi-stage request becomes expirable again the moment that stage closes.** If a later stage
  remains and the deadline has passed, the next sweep expires it. The banked approvals are not wasted -
  they are recorded, and the trail shows how far it got - but the deadline is the deadline. Granting an
  extension because progress was made turns `expires_at` into a moving target, and is rejected for
  that reason.
- **Sweeper ordering becomes load-bearing.** `Maintenance.close_due_stages!` must run *before* the
  expiry sweeper in the same pass, or a stage whose cooldown elapsed a second ago gets expired instead
  of closed. Ordering handles the elapsed case; the carve-out handles the still-running one. Both are
  needed.

Implementation note: the partial index is `expires_at where status IN ('pending', 'approved')`, so the
carve-out needs the current stage's `satisfied_at` - a join the sweeper does not have today. Pushing
`expires_at` forward by the cooldown duration would avoid the join and is **rejected**: it mutates a
creation-time fact to paper over an evaluation rule (see **Q9**).

### 6.5 Expired is not failed

"It fails and is closed" maps to the existing `expired` status, not to `failed`. The two are different
in a way that matters: `expired` is final, `failed` is not. §5.8 loops `failed` back through retry up
to `max_attempts`, and §7.2 permits `Execute` on a request that is `approved` **or** `failed` and
retryable. Routing expiry into `failed` would make every abandoned request retryable - the opposite of
closing it.

No schema change: `expired` is already in the status CHECK constraint and already in `FINAL_STATUSES`.

### 6.6 Validation the envelope owes

Both are checkable at declaration time and must be re-checked when a variant is written:

- **`expires_in > cooldown`.** A request that expires before its own cooldown window elapses can never
  reach `approved`. Both values are known at declaration, so this belongs in `verify!` (§6.12 point 6).
- **A variant's duration lies inside the envelope range**, which lies inside whatever the host
  considers sane. The same allowlist discipline as every other key.

## 7. Variant storage

```
change_request_variants
  operation_key      -- must match a live declaration; no FK (ADR-0003 posture)
  name, version, priority, active, effective_from
  workflow    jsonb  -- validated through the existing DSL on write
  conditions  jsonb  -- see section 8; empty for explicitly-selected variants
  created_by_type / _id / _label
```

Two decisions that keep the cost down:

- **One table with a `jsonb` workflow, not four definition tables mirroring the snapshot tables.** A
  variant is a *description*, exactly like `ChangeRequests::Workflow`. It is validated on write and
  never mutated. jsonb is the honest representation.
- **Reuse the existing validators.** `build_quorum` in `lib/change_requests/operation.rb` already has
  `refuse_empty_eligibility`, `refuse_threshold` and `refuse_match`. A variant is a params hash fed
  through the same path, so admin input and developer input fail identically and there is exactly one
  definition of a valid quorum. Writing a second validator is how this feature becomes a permanent
  source of divergence bugs.

**Publishing a variant should itself be a change request.** `change_requests.variant.publish`, declared
in code by developers, with its own quorum. An admin proposes, others approve, then it goes live. This
answers "who guards the guards" with zero new machinery, and it is the best demonstration the gem could
ship of its own premise.

**Dry-run before publish** is required, not optional: given a candidate variant and a sample context,
show the resolved thresholds, who would be eligible, and the diff against base. Without it admins
publish blind.

The **CRUD screen belongs in the host**. §18 lists an admin dashboard as out of scope, and pulling "who
may edit variants" into the gem drags a second authorization story with it. Ship a validated write API.

## 8. Selecting a variant

Three tiers. Only the first two are recommended.

**Tier 1 - explicit or tenant-bound.** `ChangeRequests.request!(key, variant: "eu_payroll", ...)`, or a
variant bound to a tenant. Selection is not derived from requester-controlled data, so no guarantee is
lost. **This is probably the actual demand** - "the German entity needs three approvals" is a
tenant-shaped requirement, not a conditional one.

**Tier 2 - host callback.** `op.select_variant = ->(payload:, requester:, tenant:) { ... }`. Code, in
git, full power. Does not remove the developer, but it is the right substrate: tier 3 should compile
down to this same interface.

**Tier 3 - conditions on the payload.** Ordered `(key, operator, value, type)` rows over a closed
operator set (`lt lte gt gte eq in present`), highest priority wins, no match falls back to base. About
150 lines, no `eval`. **Held, not rejected.** The objections:

- §6.12 states the payload is untyped and symbolised top-level only. `"90" < "100"` is false as
  strings. Conditions need declared types and must **refuse**, not silently return false - a quietly
  inoperative escalation rule is the worst available failure mode.
- Missing key must **fail closed** (strictest workflow), never open.
- **The requester picks their own policy, per request, and nobody decided it.** `amount: 99`. Contrast
  with section 3.1: an admin setting `threshold: 1` is a deliberate, attributable, audited act of
  organisational policy. A requester steering themselves onto a weaker workflow by choosing a payload
  value is none of those things. It is §6.12 point 3 - "approval policy is policy, not caller input" -
  being traded away. Envelopes narrow it; nothing restores it.
- Combined with dynamic thresholds it would let a requester *compute* their own threshold. **That
  combination should be refused outright, not merely bounded.**
- The engine sees the payload, not the world: `Create` has payload, requester and tenant only.

§18 already lists a conditional-routing rules engine as out for 1.0. Tier 3 does not change that
without an adopter naming a policy tiers 1 and 2 cannot express.

## 9. Change surface

| Area          | Change                                                                                                                                                                           |
|---------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Config        | `config.variants`, default `false`.                                                                                                                                              |
| Schema        | Opt-in migration: `change_request_variants` (+ versions). Additive `jsonb` provenance column on `change_request_quorums`; `variant_id` / `variant_version` on `change_requests`. |
| Registry      | `op.allow_variants` envelope; `ChangeRequests.populations.define`.                                                                                                               |
| `Workflow`    | `Quorum#threshold` becomes declared-vs-resolved, mirroring the existing `permission_match` lazy-resolution pattern in `lib/change_requests/workflow/quorum.rb`.                  |
| Serialization | `Workflow` <-> jsonb, both directions, through the existing validators.                                                                                                          |
| Resolution    | One object, called from `Create`. Default path returns the base workflow unchanged.                                                                                              |
| Errors        | `UnsatisfiableWorkflow` in the ADR-0012 taxonomy.                                                                                                                                |
| Expiry        | `op.expires_in` mandatory in `Operation#problems`; `expires_in > cooldown` check; expiry sweeper skips a `satisfied` stage and runs after `close_due_stages!`.                    |
| `verify!`     | Must validate stored rows at runtime, not only declarations at boot.                                                                                                             |
| Presenter     | Render the variant, the population, the basis and the deadline - the last one on the index row. Not optional.                                                                    |
| Test kit      | A sibling to the §14.5 shared example; sample contexts per operation for population queries.                                                                                     |

Rough order: a milestone comparable to M2 + M9a combined, call it 8-12 days for variants, +3-4 for
dynamic quorums on top since they share the envelope, provenance and integration point. Expiry adds
little to that - one envelope key and one resolved value - but the mandatory declaration and the
cooldown carve-out in section 13 step 0 are separate, smaller, and worth landing first. The code is not
the expensive part.

## 10. What we lose

Ordered by how much it hurts.

1. **Policy stops being legible from git.** Today you read the initializer and know the rule. After,
   you read the initializer *and* query the database *as of the right moment*. For a compliance-facing
   gem this is the real cost: the artefact an auditor reads is no longer a file under review. The
   envelope (section 4, gate 3) is the partial answer - the *limits* stay in git.
2. **Boot-time verification degrades.** §6.12 point 6 promises `verify!` asserts no `all_quorums` stage
   is unsatisfiable. With thresholds resolved at creation, that promise cannot be kept at boot. New
   failure mode that cannot exist today: a valid deploy and a valid variant, broken *as a pair*,
   because a declaration changed under a stored row.
3. **Satisfiability becomes a per-stage question.** Under `all_quorums` with one-approval-per-quorum
   linking (§7.1), two ratio quorums drawing on the same body can sum past it.
4. **Whoever may edit variants may change the bar for everyone else's requests.** Not an escalation to
   "can approve anything" - requester != approver still holds, so they can never clear their own request
   - but it is real authority, and granting it is the entire point of the feature. The answer is
   accountability rather than prohibition: the range declared in code, publishing gated as its own
   change request (section 7), versioned history, and the variant named on every request it shaped.
5. **CI cannot test production policy.** §14.5's "prove every operation is sound before production does"
   does not reach rows that do not exist at test time. Best substitute is a linter over live variants.
6. **Schema churn where it is most expensive.** Per ADR-0009 every change is a host migration, and
   variants are the part most likely to need one.
7. **Repositioning.** Two items currently on the §18 non-goals list come off it. The gem moves from
   "approval gate declared in code" to "policy engine with a code-declared dispatch allowlist".
   Defensible, but it is a different pitch and the README's ninety-second test changes.

**Not lost:** the dispatch allowlist, snapshot-on-create, creation-time immutability, the audit trail,
every guard, the inbox query and the whole evaluation path. All untouched.

## 11. Honest accounting of "no developers needed"

| Change                                                                      | Developer?               |
|-----------------------------------------------------------------------------|--------------------------|
| Ratios, operators, clamps, literal thresholds                               | No                       |
| Which roles or named actors are eligible (within the envelope)              | No                       |
| Membership of a named-actor list                                            | No                       |
| Number and ordering of stages, `any_quorum` / `all_quorums`                 | No, if `stages:` permits |
| The **basis** of a population - "voting body" -> "members in good standing" | **Yes**                  |
| A new **kind** of rule (weighted votes, quorum-of-quorums)                  | **Yes**                  |
| Widening the envelope itself                                                | **Yes** - deliberately   |
| What the operation does                                                     | **Yes** - by design      |

Developers leave the frequent, numeric, personnel-shaped regulatory changes. They stay for changes to
what a population *is*, because that lives in host tables the gem is architecturally forbidden from
reaching. Still a valuable claim - just not an unqualified one.

## 12. Open questions

- **Q1 - `stages: 0..3`.** A range including zero implies "a variant may delete this stage", but
  `threshold: 0` is forbidden by the CHECK constraint and would mean an auto-satisfied stage.
  *Recommendation:* do not let `0` in a threshold range mean stage removal. Removing a stage and
  lowering a threshold are different kinds of change and should not share a notation;
  `stages: { sign_off: :removable }` says it in a way no reviewer can misread as an off-by-one.
- **Q2 - unbounded ranges.** `1..` is not safe: a threshold above the eligible population is
  unsatisfiable. Permit it, warn at declaration, or require an upper bound?
- **Q3 - envelope vocabulary.** `actors:` must be expressed in the §5.3 2x2 (`actor_type` x
  `permission`). A flat list like `[users, admins, directors]` mixes the axes; it needs to be
  normalised at declaration time or it will be ambiguous for hosts with one User class and roles.
- **Q4 - actor-resolving populations.** Materialise eligible-actor rows from the population relation
  (satisfiability checkable, N rows per request) or count only (cheap, unverifiable)? Size threshold?
- **Q5 - `effective_from`.** Does a variant activate mid-review-cycle, or only for requests created
  after a boundary the admin sets?
- **Q6 - variant + `override`.** May a variant alter `op.override` permissions? Almost certainly not -
  that is the break-glass path (§8.1) and should stay in code.
- **Q7 - undeclared variants.** §5.11 handles an operation losing its declaration. What happens to
  in-flight requests when a *variant* is deactivated? Nothing, by invariant 3.3 - but the presenter
  needs copy for "created under variant X, version 3, no longer active".
- **Q8 - is `:never` still reachable?** Section 6.1 makes a period mandatory. Some operations genuinely
  should not expire. Options: no escape at all; or mandatory to *state*, with `op.expires_in = :never`
  as a value someone has to write out. The second keeps the intent - no silent `nil` - without forcing
  a deadline onto work that has none. A decision, not a default.
- **Q9 - should `expires_at` be readonly after create?** It is absent from `readonly_after_create` in
  `lib/change_requests/models/request.rb` today, while `max_attempts` beside it is present, so deadlines
  are silently mutable. That looks like an oversight against
  [ADR-0006](docs/adr/0006-creation-time-immutability.md)'s creation-time-facts list. Freezing it is the
  consistent choice; the alternative is a deliberate, audited `Extend` command with its own guard. The
  current middle ground - any caller can move a deadline and nothing records it - is the one option to
  rule out.

## 13. Recommended sequence

0. **Mandatory `expires_in`, and the cooldown carve-out** (sections 6.1 and 6.4). Independent of
   variants entirely: it is a `PLAN.md` correction, and it closes a real hole where a cooldown window
   can be expired out from under approvals that were already earned. It should land whether or not the
   rest of this document is ever accepted.
1. **Envelope first, with no variants behind it.** `op.allow_variants` as a declared, validated,
   inert no-op. It forces the vocabulary decisions (Q1, Q3) while nothing depends on them.
2. **Dynamic thresholds over named-actor quorums.** Registered population queries, ratio, operator,
   clamps, provenance. Satisfiability checkable. No DB-authored policy yet - a developer still writes
   the ratio. Delivers the council case outright and exercises the whole resolution path.
3. **Variant storage, versioning and publish-as-a-change-request.** Tier 1 selection only: explicit or
   tenant-bound.
4. **Registered populations for permission quorums.** Documented as the point where the satisfiability
   guarantee stops.
5. **Tier 3 conditional selection - held.** Only on a named adopter requirement, and never in
   combination with dynamic thresholds on the same quorum.

Steps 1-3 deliver most of the flexibility and forfeit almost none of the guarantees, because selection
never derives from requester-controlled data. They are also enough for the shrinking-department case in
section 3.1 - an admin lowering a threshold inside a declared range, or a ratio converging on `1` as the
body contracts. That case needs none of the held work below. Step 5 is where the gem's central promise starts to bend,
and it should stay unbuilt until someone can name the policy that demands it.
