# Implementation plan — M5-2: `RequestPresenter` identity, status and payload

**Ticket:** `Plan_M4.md` §6 M5-2 · **Spec:** PLAN §11, §5.12, §8.1 · **Depends on:** M4-1 (ActorRef), M5-1 (Value::*)
**Branch:** `m5-2` off `main` @ a0cc174 · **Est:** 0.75 d

## 1. Scope

```ruby
p = ChangeRequests::RequestPresenter.new(request, actor:, routes: nil, resolve_actors: true)

p.operation_key  p.operation_version  p.operation_label
p.requester      p.executer           p.tenant          # ActorRef or nil
p.status         p.payload_preview    p.payload_fields
```

Out of scope: `stages` (M5-3), `actions` (M5-4), `timeline` (M5-5), `CollectionPresenter` (M5-6), `as_json` (M5-7),
calling `payload_renderer` (M6, see §4 Q1).

## 2. What the code already gives us

| Need                    | Where it is                                                                                              |
|-------------------------|----------------------------------------------------------------------------------------------------------|
| Operation columns       | `service`, `method_name`, `operation_key`, `operation_version` on `change_requests`, readonly after create |
| Actor refs              | `request.requester / executer / tenant` → `ActorRef` via `Concerns::ActorColumns`; `tenant_label` column exists |
| Batch resolution        | `ActorResolver.call(refs)`; `registered_type` looks in both `actor_types` and `tenant_types`             |
| Label strategy          | `config.actor_label_strategy` (`:live` / `:snapshot`) — global; no per-ref "do not resolve" switch yet    |
| Payload labels          | `payload_labels` jsonb, string keys, written by `Commands::Create` from `op.payload_labels`              |
| Failed tooltip source   | `attempts.failed` → `error_message`; also `execution_failed` event body                                  |
| Expired tooltip source  | `request.expires_at`; also `expired` event metadata                                                      |
| Canceled tooltip source | latest `canceled` or `operation_undeclared` event `body` (the reason)                                    |
| Override shortfall      | `overridden` event: `body` = reason, metadata `approvals_present/required`, `incomplete_stages/quorums`  |
| Query counting          | `spec/support/query_counter.rb` (`issue_queries(n)`, `issue_no_queries`)                                 |
| Collapsed dir           | `lib/change_requests/presenters/` is collapsed → `ChangeRequests::RequestPresenter`                     |

## 3. Design

### 3.1 `lib/change_requests/presenters/request_presenter.rb`

```ruby
class RequestPresenter
  attr_reader :request, :actor, :routes

  def initialize(request, actor:, routes: nil, resolve_actors: true)
  def resolve_actors? = @resolve_actors

  delegate :operation_key, :operation_version, to: :request
  def operation_label = "#{request.service}.#{request.method_name}"

  def requester / executer / tenant   # memoised; see 3.2
  def status                          # Value::Status; see 3.4
  def payload_fields                  # [Value::Field], alphabetical; see 3.3
  def payload_preview                 # payload_fields.first(config.payload_preview_limit)
end
```

- `actor:` is required but nil is allowed (API / job callers). It's stored for M5-4 and unused here.
- `routes:` is passed through to `ActorRef#path` only. There's no ActionView reference anywhere.
- Nothing reads `ChangeRequests.operations`, so an undeclared operation renders the same as a declared one.

### 3.2 Actors and `resolve_actors:`

- **`resolve_actors: true`:** the first read of any of the three refs builds all present refs and runs
  `ActorResolver.call(refs)` once. Cost: one query per distinct actor type across requester/executer/tenant, and
  never more than that for repeated reads.
- **`resolve_actors: false`:** no ref may touch a host table, including under `actor_label_strategy = :live`. The
  `ActorRef` API has no way to do this today:
  - `resolve_with(nil)` would make `deleted?` true, which is a false claim.
  - `:snapshot` is global, and a per-presenter switch must not change global config.

  **Change to `ActorRef`:** add a `resolve: true` keyword (default unchanged).

  | `resolve: false` | behaviour                                              |
  |------------------|--------------------------------------------------------|
  | `record`         | `nil`, no query                                        |
  | `label`          | snapshot                                               |
  | `resolved?`      | `false`                                                |
  | `deleted?`       | `false`: unknown, not deleted                          |
  | `path`           | `nil`                                                  |
  | `to_h`, `==`     | unchanged: equality is the stored triple               |
  | `ActorResolver`  | skips it: `resolution_known?` is true                  |

  The presenter builds these with `ActorRef.new(**request.requester.to_h, resolve: false)`, or better, gains an
  `ActorRef#without_resolution` copy method so the column knowledge stays in `ActorRef`.

  **Spec for the `ActorRef` change first** (red then green): `deleted?` false, no queries under `:live`, resolver
  skips it.

### 3.3 Payload

- `payload.keys.sort_by(&:to_s)`, one `Value::Field` per key:
  - `key:` the string key, since jsonb keys are strings;
  - `value:` `payload_labels[key]` when that key is present, else the raw value (arrays and hashes untouched);
  - `label:` omitted, so M5-1's `Translation` + `humanize` fallback applies (`member_id` → "Member").
- A sparse `payload_labels` is normal. A stray label key with no matching payload key is ignored.
- An empty payload gives `[]` for both methods.
- `payload_preview` = `payload_fields.first(limit)`, memoised through `payload_fields`.
- `presence` is **not** used on label values: an explicit `""` label is respected, because that was the host's choice.
  Only a missing key falls back.

### 3.4 Status

`Value::Status.new(key: request.status.to_sym, tone:, tooltip:)`. Label from `change_requests.statuses.<status>`
with `humanize` fallback. Tones are declared in one frozen hash on the presenter (`STATUS_TONES`), with a spec
asserting it covers exactly `Request::STATUSES`:

| status       | tone       | tooltip                                                                                              |
|--------------|------------|------------------------------------------------------------------------------------------------------|
| `pending`    | `:neutral` | nil                                                                                                  |
| `approved`   | `:primary` | nil                                                                                                  |
| `executing`  | `:primary` | nil                                                                                                  |
| `successful` | `:success` | nil                                                                                                  |
| `failed`     | `:danger`  | last failed attempt's `error_message`                                                                |
| `rejected`   | `:danger`  | nil                                                                                                  |
| `canceled`   | `:neutral` | body of the latest `canceled` / `operation_undeclared` event                                         |
| `expired`    | `:warning` | `change_requests.statuses.expired_tooltip`, default `"Expired at %{expires_at}"`, ISO8601 UTC          |

**Override (§8.1):** when `overridden_at` is present, tone becomes `:warning`, except `failed`, which stays `:danger`.
The tooltip names the shortfall from the latest `overridden` event:
`change_requests.statuses.overridden_tooltip`, default
`"Executed without approval: %{present} of %{required} approvals. Reason: %{reason}"`.

Tooltips read the request's own rows (attempts / events). Those are gem-table queries, which is fine. They're
loaded lazily and only for the statuses that need them, and they use `request.association(...).loaded?` so
M5-6's preloading is honoured without change.

### 3.5 Configuration

`lib/change_requests/configuration.rb`:

- `attr_accessor :payload_preview_limit, :payload_renderer`. Defaults `3`, `nil`.
- `payload_preview_limit_problem`: must be an Integer `>= 0`. Zero hides the preview, which is legitimate.
- `payload_renderer_problem`: nil, or callable with 2 args `(request, view)`, using the existing `callable_with?`.
- Both added to `problems` and covered in `configuration_spec.rb` in the existing style.

## 4. Open questions (proposed default in bold; implementation proceeds on it unless told otherwise)

1. **`payload_renderer` and a headless presenter.** §11 says `payload_fields` "honours `config.payload_renderer`",
   but the renderer takes `(request, view)` and the presenter has no view. **M5-2 adds and validates the setting
   only; M6's `_payload` partial calls it** (Plan_M6.md already says "receiving the request and the view"). §11's
   line gets corrected on `plan`.
2. **`Field#label` nil vs humanized** (carried over from M5-1's PR). **Humanized, as M5-1 shipped.** Q5's
   `"label": null` example is then updated in M5-7.
3. **Status tones and tooltips** as tabled in §3.4. In particular: `executing` primary rather than warning,
   `canceled` neutral rather than danger, and override downgrading `successful` to `:warning`.
4. **The `resolve: false` `ActorRef` state** (§3.2): `deleted?` answers `false` when resolution was skipped.
   The alternative is a three-state `deleted?` (nil = unknown), which every view would then have to handle.
5. **Tooltip time format.** **ISO8601 UTC in the domain core.** `config.datetime_format` / `I18n.l` is a view
   concern (§10, M6). A view that wants local time formats `request.expires_at` itself.

## 5. TDD order and commits

One commit per step. rubocop -A after each. `bundle exec rake ci` green before each commit.

1. **Config.** Specs for defaults, validation problems and `validate!` message → `payload_preview_limit`,
   `payload_renderer`.
2. **`ActorRef` `resolve: false`** (+ `without_resolution`). Specs in `actor_ref_spec.rb` and
   `actor_resolver_spec.rb`, under both label strategies.
3. **`RequestPresenter` identity:** `operation_*`, `requester/executer/tenant`.
   `spec/change_requests/request_presenter_spec.rb`:
   - operation_label from columns after `ChangeRequests.operations.clear` (undeclared);
   - executer/tenant nil when absent;
   - **deleted actor:** hard-delete the `User` row → `requester.deleted?`, label = snapshot, no raise;
   - `resolve_actors: true` → one batch: `issue_queries(n)` where n = distinct types, then `issue_no_queries` on re-read;
   - **`resolve_actors: false` under `:live`** → `expect { p.requester.label; p.executer; p.tenant&.label }
     .to issue_no_queries` (the request is loaded first).
4. **Payload:**
   - alphabetical order with keys inserted non-alphabetically;
   - limit honoured (3 default, custom, 0, fewer fields than the limit);
   - sparse `payload_labels`;
   - empty payload → `[]`;
   - array value passes through;
   - translated field label via `with_translations`;
   - whole-structure equality in one expectation;
   - zero queries.
5. **Status:**
   - `STATUS_TONES` covers exactly `Request::STATUSES`;
   - each tooltip case built through the real commands (`SettleExecution` failure, `Expire`, `Cancel`,
     `CancelUndeclared`, `Override`), not by writing columns;
   - the override warning;
   - labels and tooltips translatable, with the fallback when no locale file is loaded.
6. **Headless probe:** extend `spec/change_requests/value_spec.rb`'s probe or add one: building a presenter needs a
   DB row, so assert `ChangeRequests::RequestPresenter` eager-loads with `rails=absent` / `action_view=absent`.
   `headless_script.rb` gets a `presenter_status=` line after its existing approve flow.
7. **Docs:** `docs/06_views_and_theming.md` doesn't exist yet. Create it with only a "Presenters" section covering
   the M5-2 surface and the two config keys; M5-7 adds the JSON contract. Add the `statuses.*` keys to the `config/locales/en.yml`
   comment block.

## 6. Acceptance mapping

| Ticket acceptance                                                         | Spec (step)            |
|---------------------------------------------------------------------------|------------------------|
| every method vs deleted actor / undeclared op / sparse labels / empty payload | 3, 4 (shared contexts) |
| `resolve_actors: false` issues no host-table query, asserted by counting  | 2, 3                   |
| preview alphabetical and honours the limit                                | 4                      |

## 7. Risks

- **`ActorRef` change touches M4 code.** It's additive: the default path is unchanged, and the existing
  actor_ref/resolver specs guard it.
- **Tooltip queries on an index page** are N+1 until M5-6 preloads `attempts`/`events`. Documented in the
  presenter, and M5-6's query-count spec closes it.
- **`STATUS_TONES` becomes part of M6's CSS and M5-7's JSON.** Changing a tone later is a contract change, so
  §4 Q3 is worth confirming before merge.
