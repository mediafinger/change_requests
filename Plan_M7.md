# Plan M7 / M8 — generators, and the host test kit

Tickets for **M7** (the six generators and their templates) and **M8** (the test kit a host requires into
its own suite), written against `PLAN.md` §13 and §14.

`PLAN.md` stays the source of truth. Where this document disagrees with it, that is a question in §6, not a
decision already taken.

**Both milestones depend on all of M6.** Three generators eject or scaffold views, and three of M8's shared
examples assert the view contract — neither can be written before the views exist.

---

## 1. Scope

| Milestone | Version | What it is                                                                  | Spec |
|-----------|---------|------------------------------------------------------------------------------|------|
| **M7**    | 0.8.0   | `install`, `operation`, `controller`, `views`, `scaffold_ui`, `migration_upgrade`, their templates, and a generate-on-a-real-app CI job | §13  |
| **M8**    | 0.9.0   | `change_requests/rspec`, `Testing`, shared contexts, builders, matchers, shared examples, test-mode toggles, `docs/07_testing.md` | §14  |

**Not here.** M9's evaluation work, notifications (M10), the release itself (M11).

---

## 2. What M0–M6 leave standing

**Already built:**

- **One generator exists**: `lib/generators/change_requests/install/templates/migration.rb.tt`, the nine-table
  install migration — written as a template from M1a and loaded directly by the suite through `GemSchema`,
  which is why it has never been allowed to rot.
- `ChangeRequests::Testing` exists with `in_parallel` and its `Barrier`, and says so in its own comment:
  "the minimum needed to write a concurrency spec (§15.3). The host-facing test kit is M8."
- `spec/integration/packaging_spec.rb` already asserts `lib/generators` ships, and pends on the three `app/`
  directories M6 creates.
- Every guard answers `allowed?` and `reason`; every presenter exposes actions — which is the whole input
  M8's matchers need.

**Declared but built by nothing:**

| Surface                                                                 | Declared in | Consumed by |
|-------------------------------------------------------------------------|-------------|-------------|
| Five of the six generators, and every template but the migration         | §13         | M7          |
| `lib/change_requests/rspec.rb` — already `loader.ignore`d, and absent     | §2, §14     | M8-1        |
| `lib/change_requests/factories.rb`, `ChangeRequests.factories_path`       | §2, §14.3   | M8-5        |
| Every matcher, shared context and shared example in §14                   | §14         | M8          |

**Three facts that shape these tickets:**

1. **The install migration template is already load-bearing.** `GemSchema` loads it to build the suite's own
   schema, so M7 inherits a template that is proven rather than one to be written. No other template has that
   property, and none of them should be trusted the same way.
2. **`spec.files` comes from `git ls-files`.** A template that is not committed does not ship, which
   M2-5 discovered the hard way when a `.rake` file failed the packaging spec while still untracked. Every
   generator's `source_root` has to resolve against packaged files (§13's packaging requirement).
3. **`Testing` is domain code.** It loads headless today, and M8 must not change that: the test kit's
   entry point is `change_requests/rspec`, which may require RSpec, while `Testing` itself may not.

---

## 3. Build order

```
M7-1  install ─→ M7-2  operation ─→ M7-3  controller
M7-4  views ─→ M7-5  scaffold_ui
M7-6  migration_upgrade
M7-7  generate-on-a-real-app CI job          (last: it exercises all six)

M8-1  rspec.rb + contexts ─┬─→ M8-2  operation sandbox and builders
                           ├─→ M8-3  matchers
                           ├─→ M8-4  shared examples
                           ├─→ M8-5  factories
                           └─→ M8-6  toggles ─→ M8-7  docs/07
```

---

## 4. Tickets — M7: generators

### M7-1 — `change_requests:install`
**Spec:** §13
**Depends on:** M6c-3

**Deliver** the generator every adopter runs first:

```bash
rails g change_requests:install \
  --actor-types=User,Admin --tenant-types=Organization --skip-tenant \
  --with-specs --mount-at=/change_requests
```

It writes: the initializer, the operations initializer, the install migration, an optional spec-support
file, an optional route, and README next-steps to stdout.

- `initializer.rb.tt` — **every configuration key, commented**, with the chosen actor and tenant types
  filled in as stubs. This file is the closest thing the gem has to a reference for §10, so it has to be
  complete and it has to stay complete.
- `operations.rb.tt` — one worked operation, commented, using `op.workflow`.
- The migration is the existing template, unchanged.
- `--actor-types` **pre-fills commented stubs and nothing else.** The generator asks nothing about the
  host's actor tables and writes no reference to them; passing nothing is fine and the schema is identical
  either way. Adding a fourth actor class later is an initializer edit, never a migration.
- **There is no `--primary-key-type`.** The gem's keys are uuids, always (§5.7, ADR-0004).
- `--with-specs` writes `spec_support.rb.tt`, which is `require "change_requests/rspec"` plus the host
  configuration M8 needs.

**A spec asserts the initializer template lists every key `Configuration` accepts**, in both directions
(**Q1**). A setting that exists and is undocumented there is invisible to adopters; a documented setting
that no longer exists is worse.

**Acceptance:** `Rails::Generators::TestCase` for every flag combination; the generated migration actually
runs against PostgreSQL; the generated initializer boots and validates; the key list and `Configuration`
agree; running it twice is idempotent or refuses clearly.
**Est:** 1 d

---

### M7-2 — `change_requests:operation NAME`
**Spec:** §13, §6.12
**Depends on:** M7-1

**Deliver** the generator that makes a new operation hard to get wrong:

```bash
rails g change_requests:operation members.update_roles
```

- Appends an `op.workflow` declaration stub to the operations initializer rather than creating a file per
  operation — operations belong together, and `verify!` reads them as one registry.
- `action.rb.tt` — a service stub with **the correct shape**: a public singleton method taking keyword
  arguments only, with `change_request_id:` accepted and commented as the idempotency key.
- `action_spec.rb.tt` — a spec that already includes both
  `it_behaves_like "a registered change request operation"` and
  `it_behaves_like "an idempotent change request target"` (M8-4).
- The generated pair passes `rake change_requests:verify` immediately, which is the point: the shape the
  generator writes is the shape `Execution::TargetContract` checks.

**Acceptance:** generated code passes `verify!` unmodified; the generated spec passes unmodified; a name
with a namespace (`orders/pay`) produces a correctly namespaced constant; the operations initializer is
appended to, not overwritten.
**Est:** 0.5 d

---

### M7-3 — `change_requests:controller`
**Spec:** §13, §12
**Depends on:** M6a-6

**Deliver** the subclass stub for hosts that want the engine's views with their own controller behaviour:

- `controller.rb.tt` — a subclass of `ChangeRequests::RequestsController` showing how to override
  `find_requests`, `actor` and `after_command`, each commented with what it is for.
- **Those three are the documented controller seams**, which means M6a-3 and M6a-6 have to actually expose
  them as overridable methods rather than inlining their bodies. Named here so M6a knows.
- The generator wires the route to the host's controller.

**Acceptance:** the generated controller boots and serves the engine's views; each of the three seams is
genuinely overridable, asserted by overriding it; the route points at the subclass.
**Est:** 0.5 d

---

### M7-4 — `change_requests:views`
**Spec:** §13, §12 Tier 4
**Depends on:** M6b-6

**Deliver** the ejection generator, documented as the escape hatch:

```bash
rails g change_requests:views                       # all of them
rails g change_requests:views --only=row,status     # just these two
rails g change_requests:views --list                # print the inventory + locals
```

- `--list` prints the same inventory M6b-6 documented — **read from one place**, so the generator, the
  document and the directory cannot disagree.
- The generator's output carries **an explicit warning** that ejected files no longer receive upstream
  changes, and a pointer back to Tier 2 and Tier 3.
- Ejected partials land in the host's `app/views/change_requests/requests/`, which Rails searches first.

**Acceptance:** ejecting all of them leaves a working page; ejecting one leaves the rest upstream;
`--only` with an unknown name fails with the inventory rather than silently writing nothing; `--list`
matches M6b-6's document, asserted against it.
**Est:** 0.5 d

---

### M7-5 — `change_requests:scaffold_ui`
**Spec:** §13, §12 Tier 5
**Depends on:** M7-4

**Confirmed wanted**, and not a generator to talk anyone out of: the scaffold is what makes a first
adoption or a heavy customisation tractable, for teams whose approvals screen has to live inside an
existing admin area with its own navigation, breadcrumbs and design system.

**Deliver:**

```bash
rails g change_requests:scaffold_ui --namespace=admin \
  --parent=Admin::BaseController --layout=admin
```

- Writes `app/controllers/admin/change_requests_controller.rb` and
  `app/views/admin/change_requests/*.html.erb` into the **host's** namespace, using the host's layout and
  route helpers, built against the presenter API. The engine is then never mounted.
- §17.1 records this as underspecified — which files, in which namespace, with which route helpers and
  layout assumptions. **M7-5 answers it** (**Q2**).
- The generated controller is the engine's, rewritten to the host's namespace: same actions, same guards,
  same commands, different parent and different route helpers.

**Acceptance:** the scaffold runs in a real generated app and serves a working index and show with the
engine unmounted; every generated view passes M6c-7's shared examples, which is what proves the scaffold is
equivalent rather than merely similar.
**Est:** 1 d

---

### M7-6 — `change_requests:migration_upgrade`
**Spec:** §13
**Depends on:** M7-1

**Deliver** the generator that makes a schema change between gem majors survivable:

- Writes the migration a host needs to move from one gem major to the next.
- **It has nothing to generate yet** — there has been no major, and the install migration is the only
  schema the gem has ever had. What ships in M7 is the mechanism and its first no-op: a versioned registry
  of schema changes, keyed by the gem version that introduced them, and a generator that emits the diff
  between the host's recorded version and the current one.
- The recorded version lives in the host's schema, not in a gem table.

**Acceptance:** running it against a current schema produces nothing and says so; the registry is asserted
to cover every version the gem has released; a spec adds a fabricated version and proves the diff is
emitted.
**Est:** 0.5 d

---

### M7-7 — Generate on a real application, in CI
**Spec:** §13's packaging requirement, §15.4
**Depends on:** M7-1 … M7-6

**Deliver** the CI job §17 names, which is the only thing that catches a template that does not ship:

- A job that creates a fresh Rails application, adds the gem **from the packaged `.gem`** rather than a
  `path:` dependency, runs `install`, `operation`, `views` and `scaffold_ui`, migrates, and boots.
- **The `path:` dependency during development hides exactly the omissions this catches** (§13): a template
  not committed is a template not in `spec.files`, and every generator's `source_root` has to resolve
  against packaged files.
- It runs the generated app's own specs, which `--with-specs` wrote.

**Acceptance:** the job fails when a template is removed from `spec.files`, proven by removing one; the
generated application boots and its specs pass; the job runs against the packaged gem, never the checkout.
**Est:** 0.75 d

---

## 5. Tickets — M8: the host test kit

### M8-1 — `change_requests/rspec` and the shared contexts
**Spec:** §14, §14.1
**Depends on:** M7-1

**Deliver** the entry point a host requires, and the two contexts it brings:

```ruby
# spec/rails_helper.rb
require "change_requests/rspec"

include_context "with change requests"
include_context "with an approved change request"
```

- `lib/change_requests/rspec.rb` — **already `loader.ignore`d** since M0, and still absent. It requires
  RSpec and registers everything M8 ships; `ChangeRequests::Testing` stays domain code that loads headless,
  and nothing in it may require RSpec (**Q3**).
- `"with change requests"` gives configuration isolation, an operations sandbox and cleanup — the same
  `dup`-the-memos trick `spec/support/global_state.rb` has used since M0, promoted to something a host can
  use.
- `"with an approved change request"` fast-forwards a request past its whole workflow, whatever that
  workflow is, so a host testing execution does not hand-build approvals.

**Acceptance:** requiring it in a host suite isolates configuration between examples, asserted by a leak
probe in both directions; `Testing` still loads in a process with no RSpec, asserted in a subprocess.
**Est:** 0.75 d

---

### M8-2 — Operation sandboxing and builders
**Spec:** §14.2, §14.3
**Depends on:** M8-1

**Deliver** the sandbox and the builders §14 lists:

```ruby
ChangeRequests::Testing.operations_sandbox { |operations| operations.define("test.noop") { … } }
ChangeRequests::Testing.actor_type_sandbox { |config| config.actor_type("TestActor") { … } }

Testing.build_request(operation_key:, requester:, payload: {})
Testing.approve_fully!(request, approvers: [alice, bob])
Testing.advance_to(request, :approved)
Testing.execute!(request, actor: carol)
Testing.orphan_actors!(request)
```

- **The sandboxes restore the originals afterwards**, so a host spec cannot mutate the real registry and a
  domain spec can run without the host's operations.
- `approve_fully!` walks whatever workflow the operation declares, satisfying every quorum of every stage
  — it must not assume one stage or one quorum, which is precisely the assumption a hand-rolled helper
  makes and then outgrows.
- `advance_to` reaches **any** status through real commands, never `update_column`: a helper that fakes a
  transition tests nothing the gem enforces.
- `orphan_actors!` hard-deletes the actor rows and keeps the snapshots, which is how a host tests the
  deleted-actor path M4-1 and M6a-5 both promise.

**Acceptance:** each sandbox restores exactly what it replaced; `approve_fully!` satisfies each of §6.9's
four shapes; `advance_to` reaches all eight statuses and refuses an unreachable one; every builder goes
through commands, asserted by the events they leave behind.
**Est:** 1 d

---

### M8-3 — Matchers
**Spec:** §14.4
**Depends on:** M8-1

**Deliver** the matcher set §14.4 lists — twelve of them, each a thin wrapper over a guard, a scope or an
event query:

```ruby
expect(request).to be_approvable_by(alice)
expect(request).to have_change_request_status(:approved)
expect(request).to have_quorum("owners").with_approvals(2)
expect(request.requester).to be_deleted_actor.with_label("Ada Lovelace")
expect { override }.to emit_change_request_event(:overridden).with_metadata(approvals_required: 2)
expect { command }.to change_request_status_from(:approved).to(:successful)
expect(presenter.actions).to include_enabled_action(:approve)
```

- **Every predicate matcher delegates to the guard the command uses.** `be_approvable_by` is
  `Guards::Approve#allowed?` and nothing else, so a matcher cannot pass where the command would refuse.
- Failure messages name the reason, not just the boolean: "expected alice to be able to approve, but the
  guard said `:requester`" is the message that saves the debugging session.
- `be_awaiting_approval_from` asserts **the inbox scope and the guard together**, which is the agreement
  §5.3 exists to protect. It ships stubbed and pending until M9c provides the scope (**Q4**).

**Acceptance:** each matcher's positive and negative forms, and each failure message, asserted; every
predicate matcher is shown to agree with its command by running both; the M9c-dependent matcher is pending
and names it.
**Est:** 1 d

---

### M8-4 — Shared examples
**Spec:** §14.5
**Depends on:** M8-3

**Deliver** the shared examples a host runs against its own code — the most valuable half of the kit,
because they test the host's declarations rather than the gem's:

- `"a registered change request operation"` — the service constant resolves; the target is a public
  singleton method; declared permissions are Strings some registered actor type can actually produce;
  `max_attempts` is at least 1; `change_request_id:` is accepted if declared. Much of this is
  `Execution::TargetContract` (ADR-0025) exposed to a host, and it must read that object rather than
  restate it.
- **`"an idempotent change request target"`** — runs the target twice with the same `change_request_id`
  and asserts a single effect. **This is the only thing anywhere that checks the contract §6.12 requires**:
  the gem cannot verify idempotence (ADR-0024), so this is how a host verifies it of itself, and it matters
  more now that idempotence is required of every target rather than declared per action.
- `"a registered actor type"` — the class resolves, `key_type` matches its real primary key, `label`
  returns a non-blank String, `permissions` returns an Array of Strings, and the batch `finder` returns the
  same records as `where(id:)`. **It is what catches a `key_type` mismatch before ids silently fail to
  resolve** (M4-2, Q2 of `Plan_M4.md`).
- `"a guarded change request command"` — for hosts writing their own commands.
- `"a change request view that survives a deleted actor"` — orphans the actors, renders, and asserts the
  snapshot label appears with **no query against the host table**.
- The three view examples M6c-7 already wrote are re-exported here rather than rewritten.

**Acceptance:** each example passes against the dummy app and **fails against a deliberately broken
fixture** — an example that cannot fail is not a test; the idempotence example detects a target that
double-writes.
**Est:** 1 d

---

### M8-5 — FactoryBot definitions
**Spec:** §14.3
**Depends on:** M8-2

**Deliver** the optional factories, loaded only if the host opts in:

```ruby
FactoryBot.definition_file_paths << ChangeRequests.factories_path
```

- `lib/change_requests/factories.rb`, plus `ChangeRequests.factories_path`.
- **No FactoryBot dependency**, not even in development beyond what the suite needs to prove the file
  loads. The builders in M8-2 are the supported path; these exist because a host with FactoryBot
  everywhere will want them.
- Factories for a request in each interesting state, built through the same commands M8-2 uses.

**Acceptance:** the file loads under FactoryBot and is inert without it; every factory produces a request
whose events match what the commands would have written.
**Est:** 0.5 d

---

### M8-6 — Test-mode toggles
**Spec:** §14.6
**Depends on:** M8-1

**Deliver** the three switches §14.6 names:

```ruby
ChangeRequests::Testing.inline_execution!    # force :inline even when config says :background
ChangeRequests::Testing.freeze_operations!   # raise on any mutation after boot
ChangeRequests::Testing.capture_events { … } # => Array<Event>, without hitting config.on_event
```

- `inline_execution!` lets a host test execution end to end without a job adapter.
- `freeze_operations!` is CI safety: a spec that mutates the registry after boot is a spec that passes in
  isolation and fails in a suite, which the gem's own `global_state.rb` exists to prevent and which a host
  has no equivalent of.
- `capture_events` collects events **without invoking `config.on_event`**, so a host asserting the trail
  does not send mail. It depends on M10's hook existing to be bypassed, and ships inert until then
  (**Q5**).

**Acceptance:** each toggle is scoped and restores afterwards; `freeze_operations!` names the operation
that was mutated; `capture_events` returns the events and leaves no side effect.
**Est:** 0.5 d

---

### M8-7 — `docs/07_testing.md`
**Spec:** §14, §2
**Depends on:** M8-4

**Deliver** the document that makes the kit findable:

- The one-line install, the two contexts, and a worked example of testing a host's own operation end to
  end: declare, request, approve, execute, assert.
- The full matcher list with a failure message for each, because a matcher is chosen by reading its
  failure.
- **A section on testing idempotence**, pointing at the shared example and explaining why the gem cannot do
  it for them (ADR-0024).
- What to do without FactoryBot, and what changes with it.

**Acceptance:** every code sample in the document runs, asserted by extracting and executing them;
the matcher list and the shipped matchers agree, checked programmatically.
**Est:** 0.5 d

---

## 6. Questions

**Five raised, five answered.** One is §17.1's M7 row, now closed.

| ID     | Question                                                              | Answer                                                                                                                                                                                                                                                                    |
|--------|------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Q1** | How does `initializer.rb.tt` stay complete as `Configuration` grows?    | **A spec compares the template's key list against `Configuration`, in both directions.** The template is the closest thing the gem has to a reference for §10, and M2, M3b and M6 each added keys — three chances to have silently drifted, had the check existed.        |
| **Q2** | `scaffold_ui`'s output is one line in §13 (§17.1).                      | **Settled in M7-5**: the engine's controller and views, rewritten into the host's namespace with the host's parent, layout and route helpers, engine unmounted. The acceptance is that the generated views pass M6c-7's shared examples — equivalent, not merely similar. |
| **Q3** | Where does the RSpec dependency live?                                  | **In `change_requests/rspec.rb` only.** `ChangeRequests::Testing` is domain code that loads headless today and must continue to; a subprocess spec asserts it. The kit's entry point may require RSpec, the domain may not.                                            |
| **Q4** | `be_awaiting_approval_from` needs a scope M9c owns.                    | **Ship it pending, naming M9c.** The same tripwire M2-6 and M5-3 use: it reddens when the scope lands rather than being remembered.                                                                                                                                     |
| **Q5** | `capture_events` bypasses `config.on_event`, which is M10.             | **Ship it inert.** It collects events correctly today, and the bypass becomes meaningful the moment M10 adds the hook. Writing it later would mean writing the collection twice.                                                                                          |

### Changes these answers make to `PLAN.md`

| Section   | Change                                                            | From |
|-----------|-------------------------------------------------------------------|------|
| **§13**   | `scaffold_ui`'s output, written out                                | Q2   |
| **§17.1** | The M7 row closes                                                  | Q2   |

---

## 7. Estimate

| Milestone | Tickets | Days     |
|-----------|---------|----------|
| M7        | 7       | 4.75     |
| M8        | 7       | 5.25     |
| **Total** | **14**  | **10.0** |

Against §17's 4 d + 3–4 d = 7–8 d.

**M8 is where the gap is**, and it is not padding. §14 lists twelve matchers, six shared examples, two
contexts, six builders and three toggles — and the shared examples are the half that has to fail against a
broken fixture to be worth anything, which roughly doubles the writing. M8-4 in particular ships the only
check of the idempotence contract that exists anywhere in the gem or outside it.

**M7-7** is also larger than a CI job sounds, because it is the only thing that catches a template which
does not ship, and proving that requires removing one and watching it fail.

---

## 8. Open questions for the maintainer

Nothing here blocks ticket work; each is a judgement worth making before the ticket that depends on it.

1. **Is `migration_upgrade` worth building before there is anything to migrate?** M7-6 ships a mechanism
   and a no-op. The argument for building it now is that the version registry has to exist *before* the
   first breaking change, not after; the argument against is that a mechanism with no user is a mechanism
   designed against guesses. It could equally be M11's problem, or 2.0's.
2. **Should the test kit ship as a separate gem?** `change_requests-rspec` would keep RSpec out of the main
   gem's orbit entirely and let the kit version independently. Against: two gems for one maintainer, and an
   adopter who does not find the kit does not use it.
3. **How much of M8 should the gem's own suite consume?** The suite currently has its own helpers —
   `WorkflowFixture`, `GuardMatrix`, the probe classes — that overlap M8's builders and matchers. Using the
   kit internally would prove it far harder than any spec can, and would also couple the suite to a
   host-facing API that is meant to be able to change.
4. **Does `--with-specs` writing into a host's suite assume RSpec?** Minitest hosts exist. The kit is
   RSpec-only by §14's design, so the install generator should probably detect and skip rather than write a
   file that cannot load — and §13 does not say.
