# ADR-0032: Present requests from the domain core, as value objects computed from the guards

- **Status:** Accepted
- **Date:** 2026-09-17

## Context

The views, a JSON API, a mailer and a background job all render the same request. If each derives its
own labels, button states and progress, they drift, and the view is the only one anybody tests. A naive
progress bar also misleads on an OR-stage, and an index page that resolves actors per row makes an N+1 on
host tables.

## Decision

- **`RequestPresenter` and `CollectionPresenter` live in the headless core** (`lib/change_requests/presenters/`),
  with no ActionView ([ADR-0001](0001-headless-domain-core.md)). `routes:` is any object answering url
  helpers. Without it every `path` is nil.
- **Every method returns `Value::*` `Data` objects** (`Field`, `Status`, `StageProgress`, `Quorum`,
  `Action`, `TimelineEntry`), compared by value, with collections frozen. Labels resolve through
  `Translation` with a `humanize` fallback. `Value::TONES` is a closed set.
- **Actions are computed from the guards the commands enforce with**
  ([ADR-0015](0015-one-guard-object-per-transition.md)). `enabled` is `allowed?` and `reason` is `message`.
  A spec runs every command for every status and role and compares.
- **Progress counts the approval links** ([ADR-0017](0017-approvals-count-through-links.md)).
  `remaining_options` lists every quorum still short, and a quorum that only names people lists who is
  left. The view joins the list with or/and according to `satisfied_by`.
- **`CollectionPresenter` owns eager loading.** It preloads `RequestPresenter::PRELOAD` for the page and
  resolves every actor ref of every presenter in one `ActorResolver` call
  ([ADR-0029](0029-actor-references-resolve-lazily-and-degrade.md)). The query count is fixed however many
  rows there are, and a spec asserts it.
- **`resolve_actors: false`** renders a complete page from the rows alone.

## Consequences

### Positive

- A disabled button and a raised error cannot disagree. Neither can a view and a JSON consumer, since both
  read the same presenter.
- Presenter specs assert whole structures in one expectation, with no rendering.
- A page of 25 requests across three actor classes costs 13 queries, the same as a page of 5.

### Negative

- `actions` is not preloaded. Every guard asks its own questions, so an index that renders buttons pays
  per row.
- `Value::Action#http_method` is not §11's `method`: a `Data` member named `method` shadows `Object#method`.
  The JSON contract maps it back.
- `stages` reads approver labels from the approval rows' snapshots, while `timeline` follows the label
  strategy. Under `:live` they can differ.
- The path helper names (`approve_request_path` …) are assumed ahead of the engine's routes (M6a-2). If
  those routes name them differently, every action's `path` is nil.
