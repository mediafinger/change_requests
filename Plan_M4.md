# Plan M9a / M4 / M5 — evaluation, actors, and presentation

Tickets for **M9a** (the linking rule and per-quorum event timing, **pulled ahead of M4**), **M4** (actor
references, visibility, tenancy) and **M5** (presenters, value objects and the `as_json` contract), written
against `PLAN.md` §7.1, §9 and §11 — and against what M0 through M3b actually shipped rather than what they
were planned to.

`PLAN.md` stays the source of truth. Where this document disagrees with it, that is a question in §6, not a
decision already taken.

---

## 1. Scope

| Milestone | Version | What it is                                                                                     | Spec        |
|-----------|---------|------------------------------------------------------------------------------------------------|-------------|
| **M9a**   | 0.4.1   | One-quorum-per-approval linking under `all_quorums`, per-quorum `quorum_satisfied` timing, named approvers | §7.1, §5.3  |
| **M4**    | 0.5.0   | `ActorRef`, batch resolution, label strategy, deep links, `visible_scope`, tenancy, `ChangeRequests::Actor` | §9, §5.7    |
| **M5**    | 0.6.0   | Presenters, the `Value::*` objects, collection eager loading, the documented `as_json` contract | §11, §5.12  |

**Not here.** The controllers and views that render any of this (M6), the generators (M7), the host test
kit (M8), cooldown (M9b), `awaiting_approval_from` (M9c), notifications (M10).

**M9a is pulled ahead of M4 and M5, and it goes first** (**Q1**). It is the oldest known defect in the gem:
`all_quorums` has been declarable since 0.3.0 while its linking rule is not built, so a stage declared
"one Admin AND two Owners" closes on two people. M5-3 renders stage progress and M5-4 renders the actions
beside it — both would otherwise faithfully display a quorum state that is wrong, and M6 would draw it.
Fixing the count before anything displays it is cheaper than fixing it after three milestones have been
written against it.

**The name stays `M9a`.** It is referenced by `Guards::Approve#countable_quorums`' own comment, by two
pending spec messages, and by §5.3, §7.1 and §17.1. Renumbering it would invalidate all of that to gain
nothing but a tidier sequence.

---

## 2. What M0–M3b left standing

**Already built and usable:**

- `config.actor_type` with `key_type`, `label`, `permissions`, `may_request`, `may_approve`, `may_execute`,
  and `config.tenant_type` with `key_type` and `label` — both validated at boot.
- `ChangeRequests.actor_attributes`, the one place a host object becomes a `(type, id, label)` triple, and
  the allowlist that raises `UnknownActorType` for a class nobody registered.
- `Concerns::ActorColumns`, generating `#requester`, `#executer`, `#approver`, `#tenant` and their writers
  across five models.
- `config.actor_identity`, snapshotted to `requester_identity` and `approver_identity`, and read by
  `same_person?` — so the requester-cannot-approve rule already sees across actor classes.
- `Authorization::Permissions` (with `.held_by`, extracted in M3a-5) and `Authorization::Callable`,
  `config.default_permission_match`, and the whole §5.3 eligibility 2×2.
- Every separation-of-duties flag: `requester_may_execute`, `approver_may_execute`,
  `requester_may_override`.

**Declared but read by nothing** — each is a ticket below, not an oversight to rediscover:

| Surface                             | Declared in                                | Consumed by                        |
|-------------------------------------|--------------------------------------------|------------------------------------|
| `config.actor_label_strategy`       | `Configuration`, validated, defaults `:live` | **M4-1** — `ActorRef#label`        |
| `t.finder`                          | §9 only; **not on `ActorType`**              | M4-2                               |
| `t.path`                            | §9 only; **not on `ActorType`**              | M4-1                               |
| `config.visible_scope`, `tenant_for`| §9.3, §10 only; **not on `Configuration`**   | M4-3                               |
| `config.payload_preview_limit`, `payload_renderer` | §10, §5.12 only; **not on `Configuration`** | M5-2 |
| `lib/change_requests/presenters/`   | a `.keep` file                               | M5                                 |

**What M9a inherits, specifically:**

- `Commands::EvaluateWorkflow` implements steps 0–4 of §7.1 **except** the cooldown branches, and its
  `satisfied?` already distinguishes `any_quorum` from `all_quorums` — the counting rule shipped in M1b.
  What is missing is the **linking** rule that decides which quorums an approval counts toward.
- `Guards::Approve#countable_quorums` returns `eligible_quorums` unchanged, and its own comment has been
  predicting the change since M1b: "M9a makes it a strict subset under all_quorums".
- `change_request_quorum_eligible_actors` rows are written by `Commands::Create` and read by
  `Authorization::Permissions#named_approver?`. **Named approvers already count**; what M9a adds is the
  linking rule around them.

**Three facts that change what these tickets have to do:**

1. **`#requester` returns a `Hash`**, not an `ActorRef`. `{ type:, id:, label: }`, plus `identity` where the
   column exists. M4-1 changes the return type of five generated readers, and roughly forty spec
   assertions compare against that hash today.
2. **Nothing resolves an actor back to a record.** There is no `finder`, no batch loading, and no code path
   anywhere in the gem that turns a stored `(type, id)` into the host object. M4-2 is the first.
3. **`Guards::*` already answer `allowed?` and `reason` for every transition**, which is the whole input
   M5-4 needs. The presenter builds the same objects the commands do; it does not re-derive anything.

---

## 3. Build order

```
M9a-1  linking rule ─→ M9a-2  event timing ─→ M9a-3  named approvers
   │
   └─────────────────────────────────────────→ M5-3  stages   (reads correct links from the start)

M4-1  ActorRef ──┬─→ M4-2  finder + batch resolution ──→ M5-6  CollectionPresenter
                 └─→ M5-2  RequestPresenter: identity, status, payload

M4-3  visible_scope + tenancy ──→ M4-4  ChangeRequests::Actor ──→ M4-5  docs/04

M5-1  Value objects ─┬─→ M5-2 ─→ M5-7  as_json + docs/06
                     ├─→ M5-3  stages
                     ├─→ M5-4  actions
                     └─→ M5-5  timeline
```

**M9a goes first, and all of it before any of M4.** Nothing in M4 depends on it, but M5-3 and M5-4 do —
and the whole point of pulling it ahead is that no presenter is written against the wrong count.

M4-1 is the only other ticket everything waits on. M4-3, M4-4 and M4-5 are independent of all of M5 and
can be done in either order.

---

## 4. Tickets — M9a: the linking rule and event timing

### M9a-1 — One quorum per approval under `all_quorums`
**Spec:** §7.1, §5.3, §17.1
**Depends on:** nothing

**Deliver** the rule §7.1 has always described and `countable_quorums` has never implemented:

- Under `any_quorum`, an approval links to **every** quorum the actor qualifies for — unchanged.
- Under `all_quorums`, it links to **exactly one**: the **lowest-`position`** quorum it qualifies for and
  which is not already satisfied.
- `Guards::Approve#countable_quorums` becomes a strict subset of `eligible_quorums`, which its own comment
  has been predicting since M1b.

**The position rule is the whole of the tie-break**, and it is declaration order (§5.3), so a host reads
their own declaration top to bottom and knows which quorum an approval will land in. "Not already
satisfied" matters: without it, the third approver of a three-quorum stage would land on a quorum that is
already closed and the stage would never complete.

**What turns green:** `spec/change_requests/workflow/shapes_spec.rb`'s pending example for §6.9 shape (b) —
"two people must not close a stage that demands three". It must be **un-pended in this ticket**, not left
passing-but-pending, which RSpec reports as a failure anyway.

**Acceptance:** §6.9 shape (b) needs three distinct people and cannot be closed by two, whatever
permissions they hold; an `any_quorum` stage is unchanged, asserted by the existing suite passing
untouched; an actor qualifying for three quorums of an `all_quorums` stage links to one; the pending
example is un-pended and passes.
**Est:** 1 d

---

### M9a-2 — `quorum_satisfied` where the transition happens
**Spec:** §7.1
**Depends on:** M9a-1

**Deliver** the event timing §7.1's divergence note describes:

- `quorum_satisfied` is emitted in **step 1**, when the quorum's status changes to satisfied — not from
  `close_stage!`.
- A quorum that **stops** being satisfied (an unapproval dropping it below threshold) emits its transition
  too, rather than being silently un-satisfied. §7.1 asks for the withdrawal to be "visible rather than
  invisible by omission".
- `stage_satisfied` still comes from `close_stage!` and still names the quorum that closed it.
- For a single-quorum stage the two arrive as a pair, one after the other — "the cost of having the
  multi-quorum case read correctly from the same code".

**This changes the trail's meaning, deliberately.** Today the trail never claims a satisfaction that was
later withdrawn, which is the compensating argument §7.1 records and rejects. After this it claims both the
satisfaction and the withdrawal, which is more information and a longer timeline (**Q6**).

**Acceptance:** an `all_quorums` stage emits one `quorum_satisfied` per quorum, each at the moment that
quorum was met and stamped with that time; a stage that never closes still emits the events for the quorums
that were met; an unapproval below threshold emits the withdrawal; `stage_satisfied` still names the
closing quorum.
**Est:** 0.75 d

---

### M9a-3 — Named approvers, end to end
**Spec:** §5.3, §6.9(d)
**Depends on:** M9a-1

**Deliver** the named-approver path as a first-class case rather than an incidental one:

- The rows and the predicate already exist. What is missing is that named approvers interact with the
  linking rule — an actor named on two quorums of an `all_quorums` stage must land on one, exactly as a
  permission-holder does.
- A quorum mixing named actors **and** permission rows is OR-ed (§5.3), and the linking rule sees the
  union.
- M5-3's `remaining_options` must then render a named quorum honestly — "1 more from Cleo or Gene", not
  "1 more from named" — which it can, because this ticket lands first.

**Acceptance:** §6.9 shape (d)'s `:named` quorum behaves identically to a permission quorum under the
linking rule; an actor named on two quorums of an `all_quorums` stage links to one; a mixed quorum counts
an actor who qualifies either way, once.
**Est:** 0.5 d

---

## 5. Tickets — M4: actors, identity and visibility

### M4-1 — `ChangeRequests::ActorRef`
**Spec:** §9.1, §5.7, §11
**Depends on:** nothing

**Deliver** the value object §9 documents, returned by every actor reader:

```ruby
ref = request.requester     # => ActorRef

ref.type       # "Admin"
ref.id         # "42"      - string, exactly as stored
ref.label      # the live label if the record resolves, else the snapshot
ref.snapshot   # the label exactly as recorded at write time
ref.resolved?  # false once the record is gone
ref.deleted?   # the inverse; drives the "(deleted)" affordance
ref.record     # the Admin, or nil - lazily resolved
ref.path(routes)
ref.to_h       # { type:, id:, label: } - what the reader used to return
```

- A plain class in `lib/change_requests/actor_ref.rb`, not a `Data`: `record` is lazily resolved and
  memoised, and `label` depends on it.
- **`config.actor_label_strategy` gets its first reader.** `:live` asks the registered `label` lambda for a
  fresh label and falls back to the snapshot when the record is gone; `:snapshot` never resolves at all and
  always returns the recorded string. §19.5's decision, finally acted on.
- `t.path` is added to `ActorType` — `->(actor, routes) { routes.admin_user_path(actor) }`, optional, and
  `ref.path(routes)` is nil when either the lambda or the record is absent.
- **`record` degrades, never raises.** An id that no longer resolves, an id that cannot be cast to the
  declared `key_type`, and an actor class that has been removed from the application entirely all produce
  `resolved? == false`, never an exception (**Q2**).
- `ActorRef` takes an already-resolved record when it has one, which is what M4-2's batch loading injects.
- The `SYSTEM_ACTOR` sentinel is an `ActorRef` too — resolved? false, label "System", `record` nil — so a
  timeline never branches on it (§19.15).

**The migration is the bulk of this ticket.** Five generated readers change return type, and the suite
compares against the old hash in roughly forty places. `to_h` keeps the shape available, so most sites
become `.to_h` and the interesting ones become `.label` or `.type`.

**Acceptance:** every actor reader returns an `ActorRef`; `to_h` equals what the reader returned before;
`:live` prefers the record and falls back to the snapshot; `:snapshot` never queries at all — asserted by
counting queries, not by trusting the branch; a deleted record leaves `deleted?` true and `label` intact; an
unregistered actor class on an old row resolves to nothing rather than raising.
**Est:** 1 d

---

### M4-2 — `t.finder` and batch resolution
**Spec:** §9.1, §11
**Depends on:** M4-1

**Deliver** the batch resolver §11 requires so `CollectionPresenter` costs one query per actor type rather
than one per row:

- `t.finder` on `ActorType` — `->(ids) { User.where(id: ids) }`, **defaulting to `Klass.where(id: ids)`**
  derived from the registered name. A host overrides it to add `includes`, a default scope, or a soft-delete
  filter.
- `ChangeRequests::ActorResolver` (or the equivalent on `ActorRef`) takes a collection of refs, groups them
  by `actor_type`, casts each group's ids per that type's `key_type`, and calls each `finder` **once**.
- **`key_type` is what governs the cast** (**Q2**): `:integer` parses and silently drops what will not
  parse, `:uuid` validates the format and drops what does not match, `:string` passes through verbatim —
  the escape hatch for ULIDs and any other key shape. A dropped id is simply unresolved.
- `finder` returns whatever it finds. Missing ids are **absent from the result**, never nil placeholders and
  never an exception: `ActorRef#resolved?` is false for them.
- Resolution is idempotent and memoised per ref, so a presenter that resolves a page and then asks a ref for
  its record issues nothing further.

**Acceptance:** three actor classes on a page of 25 requests cost three queries, asserted by counting; an
unparseable id is dropped without raising and without reaching the finder; a custom `finder` is called
exactly once per type with every id of that type; a type with no `finder` uses the derived default; an
actor class no longer defined in the application does not prevent the page from resolving the others.
**Est:** 0.75 d

---

### M4-3 — `config.visible_scope`, `config.tenant_for` and `Request.visible_to`
**Spec:** §9.3, §5.1, §5.11
**Depends on:** nothing

**Deliver** the visibility half of §9, which is three new `Configuration` attributes and one scope:

- `config.tenant_for` — `->(actor) { actor.organization }`, optional. When set, `Commands::Create` uses it
  to stamp the tenant columns when no explicit `tenant:` is passed, so a host stops threading it through
  every call site.
- `config.visible_scope` — `->(scope, actor) { … }`, **defaulting to tenant scoping when a `tenant_type` is
  registered and to `scope` otherwise**. Written against the `tenant_type` + `tenant_id` string columns, not
  a foreign key.
- `Request.visible_to(actor)` applies it, and additionally **excludes requests whose operation is no longer
  declared** (§5.11): a stranded request leaves inboxes and badges immediately, before any cleanup runs.
- `validate!` gains checks for both new lambdas' arity and callability.

**The undeclared exclusion is the subtle half.** `Request.undeclared` (M3b-2) already expresses the inverse
in SQL, so `visible_to` is its complement and the two must be written from one place or they will disagree
about an empty registry.

**Acceptance:** with no tenant type registered, `visible_to` is the identity scope plus the undeclared
exclusion; with one, a cross-tenant request is absent; a custom `visible_scope` replaces the default
entirely; `tenant_for` stamps a request created without an explicit tenant and an explicit `tenant:` still
wins; `visible_to` and `undeclared` never both contain the same row, for a declared registry and an empty
one.
**Est:** 0.5 d

---

### M4-4 — `ChangeRequests::Actor`
**Spec:** §2, §9
**Depends on:** M4-3

**Deliver** the optional host-model concern §2's layout names and §9 never describes (**Q3**):

```ruby
class User < ApplicationRecord
  include ChangeRequests::Actor
end

user.change_requests                  # requests this actor raised
user.change_requests_visible          # Request.visible_to(user)
user.may_request_change_requests?     # their registered type's may_request
```

- **Read-side conveniences only.** It registers nothing: registration is `config.actor_type` and putting it
  in two places is how the two drift.
- Each method is a thin delegation to a scope or the registry, so the concern adds no behaviour a host
  cannot get without it.
- `change_requests_awaiting_approval` is **M9c**, which owns `awaiting_approval_from`. The concern gains it
  then; it is named here so the method is not invented twice.
- Including it in a class that is not registered raises `UnknownActorType` on first use, not at include
  time — the class may be registered in an initializer that has not run yet.

**Acceptance:** each method matches calling the underlying scope directly; the concern is genuinely optional
and nothing in the gem requires it; including it in an unregistered class is refused when used, not when
loaded.
**Est:** 0.25 d

---

### M4-5 — `docs/04_authorization.md`
**Spec:** §9, §9.2
**Depends on:** M4-3

**Deliver** the document §9 promises: "Pundit and ActionPolicy get documented recipes, not gem
dependencies."

- The three concerns §9 separates, stated as three questions a host answers separately: who is the actor,
  what may they do to this request, and which requests can they see.
- The default `Permissions` policy and the 2×2 of §5.3, worked through with the dummy app's three actor
  classes.
- A **Pundit recipe** and an **ActionPolicy recipe**, each replacing `config.authorization` with a lambda
  and each showing what the gem still does itself (eligibility rows stay the inbox query, §5.3).
- `config.actor_identity`: what it buys, and the precise failure it prevents — requesting as `User#99` and
  approving as `Admin#7` defeats four-eyes silently, which is worse than a miscounted quorum.
- Visibility and tenancy from M4-3, including that `visible_scope` applies to **show as well as index**.

**Acceptance:** both recipes run against the dummy app in a spec, so neither rots; the document names no
gem the gemspec does not depend on as a requirement.
**Est:** 0.5 d

---

## 6. Tickets — M5: presenters

### M5-1 — The `Value::*` objects
**Spec:** §11
**Depends on:** nothing

**Deliver** the value objects every presenter method returns, under
`lib/change_requests/presenters/value/`:

| Object                | Carries                                                                                      |
|-----------------------|----------------------------------------------------------------------------------------------|
| `Value::Field`        | `key`, `label`, `value`                                                                        |
| `Value::Status`       | `key`, `label`, `tone`, `tooltip`                                                              |
| `Value::Quorum`       | `name`, `label`, `required`, `approved`, `satisfied?`, `approvers`                             |
| `Value::StageProgress`| `name`, `label`, `position`, `status`, `satisfied?`, `current?`, `satisfied_by`, `satisfied_via`, `remaining_options`, `quorums` |
| `Value::Action`       | `name`, `label`, `enabled`, `reason`, `method`, `path`, `confirm`, `tone`, `requires_reason`   |
| `Value::TimelineEntry`| `kind`, `label`, `actor`, `body`, `metadata`, `occurred_at`, `operation_version`               |

- All `Data`, as `Workflow::Stage` and its siblings already are: comparable by value, so a presenter spec
  asserts a whole structure in one expectation.
- Every `label` resolves through `Translation.translate` with a `humanize` fallback, the mechanism §5.9
  already uses for stage and quorum names.
- `tone` is a closed vocabulary — `:neutral`, `:primary`, `:success`, `:warning`, `:danger` — declared in
  one place, because M6's CSS class contract and M5-7's `as_json` both depend on it not growing quietly.
- **No ActionView.** `path` is a string a caller supplied or nil.

**Acceptance:** every object compares by value; every label falls back to `humanize` with no locale file;
`tone` is closed and a spec names its full set; the whole file set loads headless.
**Est:** 0.5 d

---

### M5-2 — `RequestPresenter`: identity, status and payload
**Spec:** §11, §5.12
**Depends on:** M4-1, M5-1

**Deliver** the first half of the presenter:

```ruby
p = ChangeRequests::RequestPresenter.new(request, actor:, routes: nil, resolve_actors: true)

p.operation_key  p.operation_version  p.operation_label
p.requester      p.executer           p.tenant          # ActorRef or nil
p.status         p.payload_preview    p.payload_fields
```

- `operation_label` is `"#{service}.#{method_name}"` **from the request's own columns**, so it renders
  identically for a historical request and for an operation no longer declared (§5.12).
- `config.payload_preview_limit` (default 3) and `config.payload_renderer` are added to `Configuration`,
  which has neither.
- **Payload fields are ordered alphabetically by key** (§5.12), because `jsonb` does not preserve insertion
  order and alphabetical is the only ordering that is both deterministic and explicable. §11's "schema
  order" is corrected to match (**Q4**).
- Each field renders its `payload_labels` value where one was declared and its raw value otherwise —
  sparse labels are the normal case, not an error.
- `status` carries a `tooltip` for the statuses that have something to say: `failed` names the last
  attempt's error, `expired` names the deadline, `canceled` the reason.
- **`resolve_actors: false` renders a complete page with zero queries against host tables**, because every
  label is already on the row. That is the fast path and the only path once an actor class is gone.

**Acceptance:** every method above against a request with a deleted actor, an undeclared operation, a
sparse `payload_labels` and an empty payload; `resolve_actors: false` issues no host-table query, asserted
by counting; preview ordering is alphabetical and honours the limit.
**Est:** 0.75 d

---

### M5-3 — `RequestPresenter#stages` and `remaining_options`
**Spec:** §11, §7.1, §5.3
**Depends on:** M5-1

**Deliver** stage and quorum progress, including the one place a naive progress bar lies:

- One `Value::StageProgress` per stage in position order, each carrying its quorums with `required`,
  `approved` and the approver labels that made it up.
- `satisfied_via` names the quorum that closed an `any_quorum` stage — which is exactly what
  `stage_satisfied`'s metadata already records, so the presenter reads the event rather than re-deriving it.
- **`remaining_options` renders an OR-stage honestly**: "2 more from Owners, **or** 1 from Admins", not a
  single misleading "1/2". An `all_quorums` stage lists every outstanding quorum with **and** instead.
- Approver labels come from the approval rows' snapshots, so a stage renders completely with
  `resolve_actors: false`.

**M9a-1 has already landed**, so `approved` — which counts `approval_quorums` links — is correct from the
first line of this ticket. That is the whole reason M9a was pulled ahead: written against the old linking
rule, this presenter would have rendered a stage needing three people as satisfied with two, and
`remaining_options` would have said nothing was outstanding.

**Acceptance:** each of §6.9's four shapes renders its progress correctly at every step, **including shape
(b) needing three distinct people**; a half-satisfied `any_quorum` stage lists both options; an
`all_quorums` stage lists what is outstanding; a named quorum lists its actors by label (M9a-3).
**Est:** 0.75 d

---

### M5-4 — `RequestPresenter#actions`
**Spec:** §11, §7, §8.1
**Depends on:** M5-1

**Deliver** the actions list, computed from **the same `Guards::*` objects the commands enforce with** —
which is the whole of §7's promise that a disabled button and a raised error cannot disagree:

- One `Value::Action` per transition a host can offer: approve, unapprove, reject, cancel, comment, execute,
  and `execute_override`.
- `enabled` is the guard's `allowed?`; `reason` is the guard's translated message, so the tooltip is the
  sentence the command would have raised.
- **`execute_override` is a separate action**, `tone: :danger`, `requires_reason` from
  `op.override.require_reason?`, and always confirmed — never the normal Execute quietly lighting up
  (§8.1). It is absent entirely when the operation declares no override.
- `path` is built from `routes:` when one was injected and nil otherwise, so the presenter stays usable
  from a job or an API controller with no url helpers at all.
- The guard objects are built **once** and shared with anything else on the page that needs them.

**Acceptance:** for every status × actor-role combination the cross-guard table already covers, the
action's `enabled` and `reason` equal what the command raises — asserted by running both, not by restating
the table; `execute_override` appears only where `op.override` is declared; `routes: nil` yields actions
with nil paths and no exception.
**Est:** 0.75 d

---

### M5-5 — `RequestPresenter#timeline`
**Spec:** §11, §5.5
**Depends on:** M5-1

**Deliver** the ordered timeline, one entry per event row:

- `Value::TimelineEntry` per event in `occurred_at` order, with the actor as an `ActorRef` — including the
  `System` sentinel, which needs no special case in a view.
- `label` is translated per kind through `change_requests.events.<kind>`, with a `humanize` fallback.
  M3b-2 opened that namespace with one key; this fills it for all fifteen kinds.
- Metadata is exposed as-is, and the entries that have something to say render it: `quorum_satisfied` names
  the quorum, `overridden` names the shortfall, `reaped` names the attempt and how long it was stuck.
- `operation_version` per entry, so a timeline shows a declaration changing mid-request (§5.5).

**Acceptance:** every kind in `Event::KINDS` has a label and none falls through to a missing-translation
string; a System-actor entry renders with no branching; a request whose operation changed mid-flight shows
both versions.
**Est:** 0.5 d

---

### M5-6 — `CollectionPresenter`
**Spec:** §11
**Depends on:** M4-2, M5-2

**Deliver** the collection presenter that **owns eager loading, so the N+1 is fixed once**:

- Preloads `stages: :quorums`, `stages: :approvals` and `events` for the page.
- Collects every `ActorRef` across every request, groups them by `actor_type`, and issues **one query per
  type** through M4-2's resolver. Never `find_by` per row.
- Hands each `RequestPresenter` its already-resolved refs, so no presenter resolves anything itself.
- `resolve_actors: false` skips the actor queries entirely and still renders every label.

**Acceptance:** a page of 25 requests across three actor classes issues a bounded, asserted number of
queries — counted, with the count in the spec name so a regression is legible; the same page with
`resolve_actors: false` issues none against host tables; the presenters it builds are indistinguishable
from ones built individually.
**Est:** 0.5 d

---

### M5-7 — `as_json` and `docs/06`
**Spec:** §11, §17.1
**Depends on:** M5-2, M5-3, M5-4, M5-5

**Deliver** the contract §11 calls documented and versioned, and which §17.1 records as never having been
written out (**Q5**).

The full key set, value types and `schema_version` policy are specified in **§6, Q5** of this document and
are the ticket's input, not something to be invented here.

- `RequestPresenter#as_json` returns every value above as a Hash, with **string** enum values, **ISO8601**
  timestamps, **string** ids, real booleans and explicit nulls.
- A top-level `schema_version` integer. Additive keys do not bump it; a removed key, a renamed key or a
  changed value type does.
- `docs/06_views_and_theming.md` gains the contract as its JSON half — a full worked example plus the key
  table.
- A **golden-file spec**: one fixture request rendered to JSON and compared against a checked-in file, so
  any change to the contract shows up as a diff in review rather than as a surprise for an adopter.

**Acceptance:** the documented key set and the produced key set are compared programmatically, so the
document cannot drift from the code; every value type matches the table; `routes: nil` and
`resolve_actors: false` both still produce valid JSON; the golden file changes only when the contract does.
**Est:** 0.75 d

---

## 7. Questions

**Six raised, six answered.** Three of them are §17.1 rows, now closed.

| ID     | Question                                                     | Answer                                                                                                                                                                                                                                                          |
|--------|--------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Q1** | M5 would render quorum state M9a has not made correct.        | **M9a is pulled ahead and goes first.** Every milestone after it adds surface that displays the number — M5-3 renders it, M5-4 sits beside it, M6b-2 draws it, M9c-1 queries around it — so fixing the count once, before anything reads it, is cheaper than fixing it and then revising four tickets' worth of work. The two tripwires that were holding the gap (`shapes_spec`'s pending example, and the one M5-3 would have carried) are resolved by M9a-1 rather than accumulated. §17's milestone table is reordered to match. |
| **Q6** | Moving `quorum_satisfied` to step 1 makes the trail claim satisfactions that were later withdrawn. | **Emit both, as §7.1 asks.** The current behaviour's only virtue is that it never records a satisfaction that was undone — but it achieves that by recording nothing, and a quorum on a stage that never closes gets no event at all. A trail that says "met, then withdrawn" is more honest than one that says nothing, and M9a-2 emits the withdrawal too so the pair reads correctly. |
| **Q2** | `key_type` casting rules, and what `finder` returns for ids that no longer resolve (§17.1). | **`key_type` governs the cast; anything that will not cast is dropped.** `:integer` parses and drops what will not parse, `:uuid` validates the format and drops what does not match, `:string` passes through verbatim — the escape hatch for ULIDs and every other key shape. `finder` returns what it finds: missing ids are absent, never nil placeholders and never an exception, and their refs report `resolved? == false`. This is §11's "deleted actors degrade, never raise" extended to malformed ids, which is the same failure from the reader's side. |
| **Q3** | What `ChangeRequests::Actor` actually provides (§2 names it; §9 never describes it). | **Read-side conveniences only, registering nothing.** Registration is `config.actor_type`; a concern that also registered would put the same fact in two places, which is how they drift. M4-4 lists the three methods; the inbox reader waits for M9c to own the scope. |
| **Q4** | §11 orders `payload_preview` by "schema order"; §5.12 orders it alphabetically. | **Alphabetically, and §11 is corrected.** §5.12 carries the reason — `jsonb` does not preserve insertion order, so alphabetical is the only ordering that is both deterministic and explicable — and §11 states the conclusion without it. There is no schema to order by. |
| **Q5** | `as_json` is a documented versioned contract whose keys and value types were never written out (§17.1). | **Written out below.** It closes §17.1's M5 row and is M5-7's input.                                                                                                                                                                                            |

### Q5 — the `as_json` contract

```json
{
  "schema_version": 1,
  "id": "8f14e45f-…",
  "operation_key": "members.update_roles",
  "operation_version": "2026-09-09",
  "operation_label": "Members::UpdateRoles.call",

  "status": { "key": "failed", "label": "Failed", "tone": "danger",
              "tooltip": "Timeout calling provider" },

  "requester": { "type": "Admin", "id": "42", "label": "Ada Lovelace",
                 "deleted": false, "path": "/admin/users/42" },
  "executer":  null,
  "tenant":    { "type": "Organization", "id": "…", "label": "Acme", "deleted": false, "path": null },

  "payload":         { "member_id": "42", "roles": ["editor"] },
  "payload_preview": [ { "key": "member_id", "label": "Member", "value": "Ada Lovelace" } ],
  "payload_fields":  [ { "key": "member_id", "label": "Member", "value": "Ada Lovelace" },
                       { "key": "roles",     "label": null,     "value": ["editor"] } ],

  "stages": [ { "name": "operational", "label": "Operational review", "position": 1,
                "status": "closed", "satisfied": true, "current": false,
                "satisfied_by": "all_quorums", "satisfied_via": "owners",
                "remaining_options": [],
                "quorums": [ { "name": "owners", "label": "Owners", "required": 2,
                               "approved": 2, "satisfied": true,
                               "approvers": ["Ada Lovelace", "Grace Hopper"] } ] } ],

  "actions": [ { "name": "execute", "label": "Execute", "enabled": false,
                 "reason": "This request has used all of its attempts.",
                 "method": "post", "path": "/change_requests/…/execute",
                 "confirm": null, "tone": "primary", "requires_reason": false } ],

  "timeline": [ { "kind": "requested", "label": "Requested", "body": null,
                  "actor": { "type": "Admin", "id": "42", "label": "Ada Lovelace",
                             "deleted": false, "path": null },
                  "metadata": {}, "occurred_at": "2026-09-09T10:03:41Z",
                  "operation_version": "2026-09-09" } ],

  "created_at":    "2026-09-09T10:03:41Z",
  "expires_at":    "2026-09-16T10:03:41Z",
  "executed_at":   null,
  "overridden_at": null,

  "attempts":     2,
  "max_attempts": 3,
  "retryable":    true
}
```

**Value types, as rules rather than examples:**

- Every **id** is a string, including `id` itself — `*_id` columns are strings by §5.7 and the request's
  own key is a uuid rendered as one.
- Every **timestamp** is ISO8601 in UTC with a `Z`, or `null`. Never an epoch integer, never a localised
  string: formatting is the front end's decision.
- Every **enum** — `status.key`, `status.tone`, `stage.status`, `stage.satisfied_by`, `timeline.kind`,
  `action.name`, `action.method`, `action.tone` — is a **string**, not a symbol. JSON has no symbols and a
  host reading this from another language should not have to know Ruby.
- Every **label** is already translated. A consumer renders it; it does not look it up.
- **Booleans are booleans**, never `"true"`, and absent things are `null`, never omitted — a key that
  sometimes disappears is a key every consumer has to guard.
- `payload` is the stored object verbatim. `payload_fields` is the labelled, alphabetised view of it;
  `payload_preview` is the first `payload_preview_limit` of those.
- `path` is `null` whenever no `routes:` was injected, which is the headless case and not an error.

**Versioning.** `schema_version` is an integer, `1` at M5. Adding a key does not bump it. Removing a key,
renaming one, or changing a value's type does — and the golden-file spec is what makes such a change
visible in review rather than in an adopter's bug report.

### Changes these answers make to `PLAN.md`

| Section  | Change                                                                                          | From |
|----------|-------------------------------------------------------------------------------------------------|------|
| **§11**  | `payload_preview` is ordered alphabetically, not in "schema order"                                | Q4   |
| **§9**   | `ChangeRequests::Actor` gets the description it never had                                         | Q3   |
| **§9.1** | `key_type`'s casting rules, and that an id which will not cast is dropped rather than raising     | Q2   |
| **§17.1**| The M4 row, the M5 row and the M2/M9a row all close                                               | Q1, Q2, Q5 |
| **§17**  | M9a's row moves ahead of M4; the "accepted trade" paragraph becomes a record of a trade that was taken and then closed | Q1   |
| **§7.1** | The divergence note is removed once M9a-2 lands                                                   | Q6   |

---

## 8. Estimate

| Milestone | Tickets | Days     |
|-----------|---------|----------|
| M9a       | 3       | 2.25     |
| M4        | 5       | 3.0      |
| M5        | 7       | 4.5      |
| **Total** | **15**  | **9.75** |

Against §17's 2–3 d (M9a) + 2–3 d (M4) + 3 d (M5) = 7–9 d.

**M9a-1 is a day for one method's worth of change**, because the change is to the rule every existing
approval spec was written against. The risk is not writing it; it is proving that `any_quorum` is
genuinely untouched, and that means the existing suite passing unmodified is part of the acceptance rather
than a happy accident.

The gap is almost entirely M4-1 and M5-7. **M4-1** is a day because changing the return type of five
generated readers touches roughly forty spec assertions — the same shape of work M2-2 was, and it costs the
same. **M5-7** is not "serialise the presenter": it is writing a contract down, checking the document
against the code programmatically, and pinning it with a golden file, because §11 calls it public API and
§17.1 records that nobody had ever said what it contains.

M5-3 and M5-4 are no longer the tickets to watch: M9a-1 lands before either, so both render a count that
is already correct. That was the argument for pulling it ahead, and it is worth restating as a saving
rather than a cost — three milestones of presenter and view work now get written once.
