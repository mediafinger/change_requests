# Plan M6 — the user interface

Tickets for **M6a** (controllers, routes, index), **M6b** (the show page and the partial contract) and
**M6c** (theming, i18n and the polish that makes the first two overridable), written against `PLAN.md` §12
and §11.

`PLAN.md` stays the source of truth. Where this document disagrees with it, that is a question in §7, not a
decision already taken.

**M6 depends on all of M5.** Every partial takes presenter objects or value objects, never ActiveRecord
models — that is what makes the Tier 3 contract stable, and it means nothing here can start before the
presenters exist.

**M9a has shipped by now** (`Plan_M4.md`, pulled ahead of M4), so every quorum count these views draw is
correct from the first render. M6b-2 would otherwise have been drawing a number due to change.

---

## 1. Scope

| Milestone | Version | What it is                                                                                                                                            | Spec       |
|-----------|---------|-------------------------------------------------------------------------------------------------------------------------------------------------------|------------|
| **M6a**   |         | Base + requests controllers, routes, `rescue_from`, `visible_to` on index **and** show, the index page with filters, sorting and pagination           | §12 Tier 1 |
| **M6b**   |         | The show page: stage and quorum progress, payload preview and expander, timeline, action buttons, override form, and the documented partial inventory | §12 Tier 3 |
| **M6c**   | 0.7.0   | i18n, the CSS class contract, the optional stylesheet, Turbo-optional responses, Stimulus fallbacks, `bin/demo`, view and request specs               | §12 Tier 2 |

**Not here.** The generators that eject or scaffold these views (M7), the host test kit (M8),
`awaiting_approval_from` and the inbox it powers (M9c), notifications (M10).

---

## 2. What M0–M5 leave standing

**Already built:**

- `config/routes.rb` exists and draws **nothing**. The engine spec asserts `routes=0`, deliberately.
- `Guards::*` answer `allowed?` and a translated `reason` for every transition, and M5-4 has already turned
  them into `Value::Action`s. A controller action is a guard, a command and a redirect.
- The whole error taxonomy, with `Refusal#message` translated — so one `rescue_from` produces a flash.
- `config/locales/en.yml` carries every guard reason and the `events` namespace M3b-2 opened.
- `Request.visible_to` (M4-3) and the `ActorRef` every actor partial renders (M4-1).

**Declared but read by nothing** — each is a ticket below:

| Surface                                                                           | Declared in                          | Consumed by  |
|-----------------------------------------------------------------------------------|--------------------------------------|--------------|
| `config.mount_ui`, `parent_controller`, `layout`, `routes`, `per_page`, `filters` | §10 only; **not on `Configuration`** | M6a-1        |
| `config.current_actor`                                                            | §9 only; **not on `Configuration`**  | M6a-1        |
| `config.stylesheet`, `datetime_format`, `helper_module`                           | §10 only; **not on `Configuration`** | M6c-1, M6c-3 |
| `app/controllers/`, `app/helpers/`, `app/views/`                                  | §2 layout                            | M6a, M6b     |

**Three facts that shape these tickets:**

1. **The packaging spec already pends on all three `app/` directories.** Four examples turn themselves on
   the moment M6 creates them, so a directory that ships but is not packaged fails immediately.
2. **The gem's UI never creates a request.** `config.routes`' full list is
   `index show approve unapprove reject execute cancel comment` — there is no `new` and no `create`,
   because §6.5 makes raising a request the host's own call site. That matters for `requestable_by?` (§7,
   **Q2**).
3. **No JavaScript is required for anything.** Turbo and Stimulus are enhancements over markup that already
   works, which is a constraint on M6a and M6b, not a feature of M6c.

---

## 3. Build order

```
M6a-1  config keys ─→ M6a-2  routes ─→ M6a-3  BaseController ─┬─→ M6a-4  index scopes ─→ M6a-5  index view
                                                              └─→ M6a-6  member actions

M6b-1  show layout ─┬─→ M6b-2  stage progress
                    ├─→ M6b-3  payload
                    ├─→ M6b-4  timeline
                    └─→ M6b-5  actions, override and comment forms ─→ M6b-6  the partial contract

M6c-1  class contract ─→ M6c-2  stylesheet
M6c-3  i18n sweep          M6c-4  Turbo ─→ M6c-5  Stimulus ─→ M6c-6  bin/demo ─→ M6c-7  view specs
```

M6b-1 is the only ticket with a decision in it (**Q1**); the rest of M6b is markup against a settled layout.

---

## 4. Tickets — M6a: controllers, routes and the index

### M6a-1 — The UI configuration keys
**Spec:** §10, §9, §12
**Depends on:** nothing

**Deliver** the settings §10 lists and `Configuration` has none of:

```ruby
config.mount_ui          = true
config.current_actor     = ->(controller) { controller.current_user }
config.parent_controller = "ApplicationController"
config.layout            = "application"
config.routes            = %i(index show approve unapprove reject execute cancel comment)
config.per_page          = 25
config.filters           = %i(type tenant status stage)
```

- `validate!` gains their checks: `routes` and `filters` are subsets of closed vocabularies declared in one
  place, `per_page` is a positive integer, `parent_controller` and `layout` are strings, `current_actor` is
  callable or nil.
- **Every UI key is inert when `mount_ui` is false** (§10), and a spec asserts that a headless boot with
  all of them set to nonsense still validates — the keys are the UI's business, not the domain's.
- `config.current_actor` is new here, not in §10's block at all: §9 introduces it and §10 forgot it
  (**Q4**). It takes the controller, because a host's `current_user` is a controller method.

**Acceptance:** each key defaults as §10 prints it; `validate!` refuses an unknown route name, an unknown
filter name and a non-positive `per_page`; a headless process with `mount_ui = false` validates whatever
the UI keys contain.
**Est:** 0.5 d

---

### M6a-2 — Routes, and the mount that can be declined
**Spec:** §12 Tier 0/1, §10
**Depends on:** M6a-1

**Deliver** `config/routes.rb`, drawn from `config.routes` rather than hardcoded:

```ruby
mount ChangeRequests::Engine, at: "/change_requests"
```

- `resources :requests, only: [...]` plus one member `post` per action name, each drawn **only if
  `config.routes` includes it**. A host that wants a read-only screen sets `%i(index show)` and the approve
  path does not exist — which is a 404, not a 403, because the route is genuinely absent.
- `config.mount_ui = false` draws nothing at all, so mounting the engine is harmless and `Tier 0` costs a
  host nothing.
- The engine's route set is empty until this ticket, and `dummy_engine_spec` asserts exactly that today —
  it changes with this ticket and becomes the assertion that the allowlist works.

**Acceptance:** the default config draws eight routes; a reduced `config.routes` draws exactly those;
`mount_ui = false` draws none; path helpers are namespaced to the engine and do not leak into the host.
**Est:** 0.5 d

---

### M6a-3 — `BaseController`
**Spec:** §12 Tier 1, §9.3, §7
**Depends on:** M6a-2

**Deliver** the controller every other one inherits from:

- **Parent class from `config.parent_controller`**, resolved at load, so the host's
  `before_action :authenticate!`, its layout, its CSRF configuration and its `current_user` all apply
  without the gem knowing any of them exist.
- `current_actor` from `config.current_actor`, called with the controller. When it is nil the controller
  refuses every action with a 403 — an unauthenticated request should never reach a guard.
- **One `rescue_from ChangeRequests::Error`**, turning a refusal into a flash and a redirect back. The
  message is already translated (§7); the controller adds nothing to it.
- `rescue_from ActiveRecord::RecordNotFound` → 404, which is also what a request outside
  `visible_to` produces (§9.3).
- `helper_method :current_actor`, and `config.helper_module` prepended to `RequestsHelper` when set.
- The layout from `config.layout`.

**Acceptance:** a host's `before_action` runs; an unregistered actor class produces a 403 rather than a
500; every error in the taxonomy produces a flash and a redirect, asserted across the whole taxonomy rather
than one example; a nil `current_actor` never reaches a command.
**Est:** 0.75 d

---

### M6a-4 — Index scopes: filter, sort, paginate
**Spec:** §12 Tier 1, §9.3
**Depends on:** M6a-1

**Deliver** the query half of the index, as scopes on `Request` rather than logic in a controller:

| Param    | Values                                       | Scope                                                     |
|----------|----------------------------------------------|-----------------------------------------------------------|
| `type`   | an `operation_key`, or `Service.method_name` | `where(operation_key:)` / `where(service:, method_name:)` |
| `tenant` | `Type:id`                                    | `where(tenant_type:, tenant_id:)`                         |
| `status` | one or more of `STATUSES`                    | `where(status:)`                                          |
| `stage`  | a stage `name`                               | joins the current stage on `name`                         |

- **Unknown params are ignored rather than raising**, so a stale bookmark degrades to an unfiltered list.
  So is an unknown status value, and a `tenant` that does not parse.
- Sorting is `created_at DESC` by default, with `updated_at` and `expires_at` as the only alternatives —
  a closed list, because a sort column from a query parameter is an ordering injection otherwise.
- **Pagination is hand-rolled `LIMIT`/`OFFSET`** over `config.per_page` (**Q3**), with a page object
  carrying `current`, `total`, `next` and `previous` so the view does no arithmetic.
- Every scope composes with `visible_to`, and the controller applies `visible_to` **first**.

**Acceptance:** each filter narrows and all four combine; unknown params, unknown statuses and malformed
tenants are ignored; an unknown sort column falls back to the default rather than reaching SQL; the last
page and an empty result both paginate correctly; `visible_to` cannot be filtered around.
**Est:** 0.75 d

---

### M6a-5 — The index page
**Spec:** §12 Tier 1/3
**Depends on:** M6a-3, M6a-4, M5-6

**Deliver** the index view and the partials §12's inventory names for it: `index`, `_filters`, `_table`,
`_row`, `_status`, `_payload_preview`, `_actor`, `_datetime`, `_empty`.

- Built entirely on `CollectionPresenter`, so the page costs a bounded number of queries and the spec says
  how many in its name.
- **Every partial takes presenter or value objects**, never a model. That is the Tier 3 contract, and it is
  established here rather than retrofitted in M6b.
- `_actor` handles three cases in one place: a resolved actor, a deleted one rendered
  "Ada Lovelace (deleted)" with no link, and the `System` sentinel.
- `_empty` is a real partial, because "no requests" is the first thing most adopters see.
- Plain ERB, no framework class names, no JavaScript.

**Acceptance:** the page renders with a deleted actor, an undeclared operation, an empty payload and an
empty collection; no raw UUID appears where an actor label belongs; the query count is asserted.
**Est:** 0.75 d

---

### M6a-6 — Member actions, and `Operation#requestable_by?`
**Spec:** §12 Tier 1, §7, §7.2 †
**Depends on:** M6a-3

**Deliver** the six member actions and the predicate §7.2 assigns to this milestone:

- One action per command: approve, unapprove, reject, cancel, comment, execute — each a `button_to` form
  that works with JavaScript disabled, each calling its command and redirecting back with a flash.
- Reject, cancel and override take a reason; the form posts it and the command's own
  `:reason_required` refusal is what a missing one produces. The controller validates nothing the command
  already validates.
- `execute_override` posts to the same path with `override: true`, and is the only action that renders a
  form rather than a button (§8.1).
- **`Operation#requestable_by?(actor)`** — the operation is declared and complete, and the actor's
  registered type declares `may_request`. It reads `Operation#problems` (M2-3), which is the whole reason
  that method exists. It renders no button here (**Q2**).

**Acceptance:** every action works without JavaScript; a refusal produces a flash and no write; the reason
field's absence is refused by the command rather than by the controller; `requestable_by?` agrees with
`Commands::Create` for every case Create refuses, asserted by running both.
**Est:** 0.75 d

---

## 5. Tickets — M6b: the show page

### M6b-1 — The show page layout
**Spec:** §12 Tier 3, §17.1
**Depends on:** M6a-5

**Deliver** `show.html.erb` and the layout §17.1 records as missing (**Q1**, which settles it). Top to
bottom:

1. **Heading** — `_operation` (`Service.method_name`), the status pill, and the `overridden` badge when
   `overridden_at` is set.
2. **Facts** — requester, created, expires, and executer plus executed-at once there is one. A definition
   list, so a host can restyle it without restructuring it.
3. **Payload** — `_payload_preview` inline, with `_payload` in a `<details>` expander beneath.
4. **Stage progress** — `_stage_progress`, every stage in order with the current one marked.
5. **Actions** — `_actions`, then `_override_form` beneath it when the operation declares an override and
   the actor may take it.
6. **Timeline** — `_timeline`, newest last, with `_comment_form` beneath it.

**What renders when things are absent**, which is the half §17.1 actually asks about:

- A **nil executer** renders nothing at all — not "not executed yet", which is noise on every pending row.
- An **empty timeline** cannot happen: every request has a `requested` event. The partial still handles it,
  rendering `_empty`, because a host filtering the timeline can produce one.
- **No actions enabled** renders the disabled buttons with their reasons, not an empty block: "why can I
  not approve this" is the question the page exists to answer.
- An **undeclared operation** renders fully, with a banner saying the operation is no longer declared and
  every action disabled but comment and cancel (§5.11).

**Acceptance:** the page renders for a request in each of the eight statuses; each absence above renders as
specified; the order is asserted structurally so a reordering is a failing spec rather than a surprise.
**Est:** 0.75 d

---

### M6b-2 — Stage and quorum progress
**Spec:** §12, §11, §5.3
**Depends on:** M6b-1, M5-3

**Deliver** `_stage_progress` and `_quorum`, rendering `Value::StageProgress` and `Value::Quorum`:

- One row per stage, in position order, with the current stage marked and satisfied ones distinguished.
- Per quorum: its label, `approved/required`, and the approver labels that made it up.
- **An OR-stage renders honestly** — `remaining_options` as "2 more from Owners, **or** 1 from Admins",
  never a single "1/2" (§11). An AND-stage joins with "and".
- A nameless quorum borrows its stage's label (§5.9), so a single-quorum stage does not render an empty
  heading.

**M9a landed before M4**, so the counts this renders are correct: an `all_quorums` stage shows as
satisfied only when it genuinely is, and a named quorum lists its actors by label. That is what pulling
M9a ahead bought — this partial draws the number once.

**Acceptance:** each of §6.9's four shapes renders at every step; a half-satisfied `any_quorum` stage lists
both options; a nameless quorum renders its stage's label.
**Est:** 0.5 d

---

### M6b-3 — Payload preview and expander
**Spec:** §12, §5.12
**Depends on:** M6b-1, M5-2

**Deliver** `_payload_preview` and `_payload`:

- The preview is the first `config.payload_preview_limit` fields, alphabetically by key, labelled where
  `payload_labels` declared one and raw otherwise.
- The full payload expands in place in a `<details>` element, **with no JavaScript required** (§5.12).
- `config.payload_renderer` replaces both when set, receiving the request and the view.
- A nested value renders readably rather than as an inspected Ruby hash — string keys inside, because that
  is what round-trips through `jsonb`.

**Acceptance:** an empty payload, a payload with no labels, a sparse-labelled payload and a deeply nested
one all render; the expander works with JavaScript disabled; `payload_renderer` takes over completely.
**Est:** 0.5 d

---

### M6b-4 — The timeline
**Spec:** §12, §5.5
**Depends on:** M6b-1, M5-5

**Deliver** `_timeline` and `_timeline_entry`:

- One entry per `Value::TimelineEntry`, in order, each with its actor through `_actor` and its time through
  `_datetime`.
- The entries that carry metadata render it: `quorum_satisfied` names the quorum, `overridden` names the
  shortfall it crossed, `execution_failed` names the error, `reaped` names the attempt and how long it was
  stuck.
- A `System`-actor entry renders with no link and no special case in the markup.
- `_comment_form` beneath, posting to the comment action.

**Acceptance:** every kind in `Event::KINDS` renders with a label and no missing-translation string; a
System entry renders; metadata-carrying kinds show theirs; the comment form works without JavaScript.
**Est:** 0.5 d

---

### M6b-5 — Actions, the override form and the comment form
**Spec:** §12, §8.1
**Depends on:** M6b-1, M5-4

**Deliver** `_actions`, `_action_button`, `_override_form` and `_comment_form`:

- One button per `Value::Action`. **A disabled action renders its reason** — as a `title` and as visible
  text, because a tooltip alone is invisible on touch.
- Every button is a real form (`button_to`), so nothing depends on JavaScript.
- `_override_form` is the danger path: a required reason field when `require_reason`, a confirmation, and
  wording that says what is being bypassed. It appears only when the operation declares an override.
- `confirm` renders as a `data-turbo-confirm` **and** a native `confirm` fallback.

**Acceptance:** a disabled action shows the same sentence the command would raise, asserted by running
both; every button submits without JavaScript; the override form is absent for an operation with no
override; a missing reason is refused by the command.
**Est:** 0.5 d

---

### M6b-6 — The partial inventory as a contract
**Spec:** §12 Tier 3
**Depends on:** M6b-2, M6b-3, M6b-4, M6b-5

**Deliver** the document §12 calls "the single most valuable piece of view support in the plan" — the
partial inventory and its locals, as a semver-covered contract.

- `docs/06_views_and_theming.md` gains the full table: every partial, its locals, their types and its
  purpose.
- **A spec compares the documented inventory against the files on disk**, in both directions, so a partial
  added without documentation and a documented partial that no longer exists are both failures.
- A second spec asserts each partial renders standalone with only its documented locals — which is what
  makes an override drop-in.
- The document states plainly what a host gets and gives up at each tier, and that an overridden partial
  keeps receiving upstream fixes while an ejected one does not.

**Acceptance:** the inventory and the directory agree, checked programmatically; every partial renders with
only its documented locals; no partial receives an ActiveRecord model.
**Est:** 0.5 d

---

## 6. Tickets — M6c: theming, i18n and polish

### M6c-1 — The CSS class contract
**Spec:** §12 Tier 2
**Depends on:** M6b-6

**Deliver** the class names §12 lists, applied throughout and asserted:

```
.cr-table  .cr-row  .cr-row--failed
.cr-status  .cr-status--pending  .cr-status--approved  .cr-status--executing  .cr-status--failed
.cr-stage  .cr-stage--current  .cr-stage--satisfied  .cr-stage__count
.cr-btn  .cr-btn--approve  .cr-btn--execute  .cr-btn--reject  .cr-btn--disabled
.cr-timeline  .cr-timeline__entry  .cr-timeline__entry--execution_failed
```

- Every modifier is derived from a value object's own vocabulary — `status.key`, `action.name`,
  `entry.kind`, `tone` — so the contract cannot drift from the data.
- **A spec asserts the rendered class set**, because these are public API: a host's stylesheet breaks when
  one changes, and semver has to cover them.
- No framework class names anywhere: a Tailwind or Bootstrap name would bind the gem to one design system.

**Acceptance:** every documented class appears in the rendered output where documented; every status, tone,
action and event kind produces its modifier; no class outside the `cr-` prefix is emitted.
**Est:** 0.5 d

---

### M6c-2 — The optional stylesheet
**Spec:** §12 Tier 2
**Depends on:** M6c-1

**Deliver** `config.stylesheet` and the ~150-line sheet it enables:

- Built entirely on CSS custom properties, so a host restyles it with a handful of variable overrides and
  **no `!important`**: `--cr-color-danger`, `--cr-radius`, `--cr-font`, and the rest declared in one block.
- Off unless `config.stylesheet = true`, and inert when the engine is not mounted.
- Served through the host's asset pipeline when there is one, and inline-able when there is not — the gem
  does not depend on Sprockets or Propshaft.
- Legible at a small viewport without a grid framework.

**Acceptance:** the page renders unstyled and usable with the sheet off; every colour, radius and font in
the sheet resolves from a custom property; overriding three properties visibly restyles it with no
specificity fight.
**Est:** 0.5 d

---

### M6c-3 — Every string through I18n
**Spec:** §12 Tier 2, §5.9
**Depends on:** M6b-6

**Deliver** the i18n sweep, and the seams around it:

- Every string in every view under `change_requests.*`: statuses, action labels, confirmations, empty
  states, headings, the override warning, and the undeclared-operation banner. Guard reasons and event
  labels already exist.
- `config.datetime_format` — an `I18n.l` format key, or a lambda receiving the time — read by `_datetime`,
  which is the one place a timestamp is formatted.
- `config.helper_module` prepended to `RequestsHelper`, so a host overrides one helper without ejecting a
  partial.
- **A spec walks every rendered page and fails on any untranslated string**, in the shape `refusal_spec`
  already uses for the reason vocabulary: a literal in a view is the failure mode this prevents.

**Acceptance:** no view contains a user-visible literal; every key resolves in `en`; a missing key falls
back rather than rendering `translation missing`; `datetime_format` accepts both a symbol and a lambda.
**Est:** 0.75 d

---

### M6c-4 — Turbo-optional responses
**Spec:** §12 Tier 1
**Depends on:** M6a-6

**Deliver** the progressive-enhancement half of the controller:

- `turbo_stream` responses **only when `turbo-rails` is defined**, guarded the way the engine guards Rails
  itself (§1). An HTML redirect otherwise, and the HTML path is the one the specs exercise first.
- A Turbo response updates the actions, the status pill, the stage progress and the timeline — the four
  regions a decision changes — rather than replacing the page.
- `data-turbo-confirm` on the actions that declare a `confirm`, with the native fallback from M6b-5.

**Acceptance:** every action works with `turbo-rails` absent, asserted in a subprocess as §15.5 does for
Rails; with it present the four regions update; a host without Turbo sees no Turbo markup at all.
**Est:** 0.5 d

---

### M6c-5 — The two Stimulus controllers
**Spec:** §12 Tier 1
**Depends on:** M6c-4

**Deliver** the two enhancements §12 names, each with a server-rendered fallback that is the real
behaviour:

- **Relative time** — `I18n.l` renders the absolute time server-side; the controller replaces it with
  "3 minutes ago" and a `title` carrying the absolute one.
- **Clipboard** — copies the request id; without JavaScript the id is simply selectable text.
- Shipped as importmap-pinnable assets, with no build step and no `jsbundling` dependency. A host that uses
  neither importmap nor a bundler loses nothing, because both are enhancements.

**Acceptance:** every page is fully usable with JavaScript disabled, asserted rather than assumed; the
importmap pin is documented; neither controller is required for any action to work.
**Est:** 0.5 d

---

### M6c-6 — `bin/demo`
**Spec:** §15.1, §12
**Depends on:** M6c-2

**Deliver** the runnable demo the dummy app has been building toward:

- Boots the dummy application with the UI mounted, seeds a handful of requests across every status — one
  pending, one mid-stage, one approved, one executing, one failed and retryable, one overridden, one with a
  deleted actor, one whose operation is undeclared — and opens a browser.
- Idempotent: running it twice reseeds rather than accumulating.
- It is the fastest way to see the gem, and the fastest way to notice that a page looks wrong.

**Acceptance:** it boots from a fresh checkout after `bin/setup`; every seeded state renders; running it
twice leaves the same data.
**Est:** 0.5 d

---

### M6c-7 — View and request specs, and the shared examples hosts get
**Spec:** §15.2, §12
**Depends on:** M6c-3

**Deliver** the suite §12 promises, and the half of it hosts can run:

- Request specs for every action: the happy path, every guard refusal as a flash, a cross-tenant `show`
  returning **404** (§9.3), and a route absent from `config.routes` returning 404.
- View specs for the class contract, disabled actions rendering their reason, no raw UUID where an actor
  label belongs, and every action button being a real form.
- **Shared examples shipped for hosts** (§12's closing section), so an ejected or hand-written view gets a
  regression suite for free:

  ```ruby
  it_behaves_like "a change requests index view", path: admin_change_requests_path
  it_behaves_like "a change requests show view", path: admin_change_request_path(request)
  it_behaves_like "a change requests row partial", partial: "admin/change_requests/row"
  ```

- They live where M8's test kit will pick them up, so M8 exposes rather than rewrites them.

**Acceptance:** every route has a request spec including its refusals; the shared examples pass against the
gem's own views, which is what proves they will mean something against a host's.
**Est:** 0.75 d

---

## 7. Questions

**Six raised, six answered.** One is §17.1's M6b row, now closed.

| ID     | Question                                                                                                                                                             | Answer                                                                                                                                                                                                                                                                                                                                                             |
|--------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Q1** | The show page has an inventory of partials but no layout (§17.1).                                                                                                    | **Settled in M6b-1**: six blocks in a stated order, plus what each absence renders. The absences are the part §17.1 was really asking about — a nil executer renders *nothing*, and a fully-disabled action set renders the buttons with their reasons rather than an empty block, because "why can I not approve this" is the question the page exists to answer. |
| **Q2** | §7.2 says `requestable_by?` ships with M6a, "the first milestone that renders such a button" — but `config.routes` has no create path and the inventory has no form. | **It ships as a public predicate with no button behind it.** The gem never creates a request: §6.5 makes that the host's own call site, so the button lives in the host's UI and this is what it consults. §7.2's parenthetical is wrong about the gem rendering one, and is corrected.                                                                            |
| **Q3** | Pagination: a gem, or hand-rolled?                                                                                                                                   | **Hand-rolled `LIMIT`/`OFFSET`.** Kaminari and Pagy are both reasonable and picking either binds every adopter to the maintainer's taste — including adopters who already use the other one. `config.per_page` plus a small page object is a dozen lines, and the view does no arithmetic either way.                                                              |
| **Q4** | `config.current_actor` is in §9 and missing from §10's block.                                                                                                        | **It is a real setting and §10 is amended.** The controller cannot work without it, and every other controller-facing key is listed there.                                                                                                                                                                                                                         |
| **Q5** | A request outside `visible_to`: 404 or 403?                                                                                                                          | **404**, as §9.3 already requires. A 403 confirms the row exists, which is precisely what tenant scoping is hiding.                                                                                                                                                                                                                                                |
| **Q6** | How do two Stimulus controllers ship without an asset-pipeline dependency?                                                                                           | **As importmap-pinnable files under the engine's `app/assets`, documented and optional.** Neither is required for anything to work (M6c-5), so a host with no pipeline at all loses nothing and needs no configuration.                                                                                                                                            |

### Changes these answers make to `PLAN.md`

| Section    | Change                                                             | From |
|------------|--------------------------------------------------------------------|------|
| **§12**    | The show page layout, written out                                  | Q1   |
| **§7.2 †** | `requestable_by?` answers a host's button, not one the gem renders | Q2   |
| **§10**    | `config.current_actor` joins the configuration block               | Q4   |
| **§17.1**  | The M6b row closes                                                 | Q1   |

---

## 8. Estimate

| Milestone | Tickets | Days      |
|-----------|---------|-----------|
| M6a       | 6       | 4.0       |
| M6b       | 6       | 3.25      |
| M6c       | 7       | 4.0       |
| **Total** | **19**  | **11.25** |

Against §17's 3 d + 2–3 d + 2–3 d = 7–9 d.

The overrun is concentrated in the parts §12 describes as contracts rather than markup. **M6b-6** and
**M6c-1** are not view work at all: they are two public APIs — the partial inventory with its locals, and
the CSS class set — each of which has to be documented, asserted against the code in both directions, and
then covered by semver. §12 calls the first "the single most valuable piece of view support in the plan",
and a contract nobody checks is not a contract.

**M6c-3** is also larger than an i18n pass sounds, because the spec that makes it stick walks every
rendered page looking for literals, and writing that is most of the ticket.

---

## 9. Open questions for the maintainer

Nothing here blocks ticket work; each is a judgement worth making before the ticket that depends on it.

1. **Does the index need `awaiting_approval_from` before M9c?** "Requests waiting on me" is the first
   filter most adopters will want, and M6a ships four filters that are not it. Either M6a-4 gains a fifth
   filter that M9c then implements properly, or the index ships without the view most users want and gains
   it two milestones later.
2. **Should the engine ship an HTTP API controller after all?** §12 defers it explicitly, and M5-7's
   `as_json` makes it perhaps forty lines. The argument against is maintenance surface; the argument for is
   that every Tier 6 adopter writes the same controller.
3. **How is `config.parent_controller` resolved under reloading?** Constantizing a host controller at load
   is the same problem `verify!` has with services (ADR-0025), and the answer there was to resolve late and
   hold nothing. M6a-3 should probably do the same, but a controller superclass cannot be resolved lazily
   the way a service can.
