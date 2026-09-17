# ADR-0029: Resolve actor references lazily, in batches, and degrade rather than raise

- **Status:** Accepted
- **Date:** 2026-09-16
- **Corrected:** 2026-09-17

## Context

[ADR-0003](0003-actor-references-as-triples.md) stores who did what as a `(type, id, label)` triple
with no foreign key. Rendering it needs the record for a live label and a link. Every row on a page
names several actors, so resolving each on its own is an N+1 per actor class. The row also outlives
the record, the class and sometimes the key type: a five-year-old request can name a deleted user, a
model that was removed, or an integer id in a table since migrated to uuids.

## Decision

**Every actor reader returns a `ChangeRequests::ActorRef`.** The triple is always complete, so
`type`, `id`, the snapshot and `to_h` answer with no query. `record` resolves on first read and
memoises hits and misses alike. `to_h` returns the stored columns, the **snapshot** label included:
reading a row does not query.

**Resolution goes through the registration.** `RegisteredType#finder` takes an array of ids and
defaults to `Klass.where(id:)`, resolved at call time so a reloaded class is found. `#cast_id` turns
the string column back into the key type: `:integer` parses, `:uuid` must match the format, anything
else passes verbatim. An id that does not cast is dropped before the finder sees it.

**A page resolves in one query per actor type.** `ActorResolver.call(refs)` groups unresolved refs by
type, calls each finder once with every cast id, and fills each ref through `resolve_with`. A single
ref resolving itself uses the same `cast_id` and `finder`, so the two paths cannot disagree.

**Resolution degrades, never raises.** An unregistered type, a class the application no longer
defines, a class with no `where` and no `finder` (a plain Ruby actor), an uncastable id and a deleted
record all resolve to `nil`. The ref reports `deleted?`, its `label` falls back to the snapshot, and
`path` returns `nil` - as it does for a tenant, whose registration declares no path.

**Not resolving is a state of its own.** `ActorRef#without_resolution` answers from the row under
either label strategy, never queries, and reports `deleted?` false, because nobody looked.
`RequestPresenter.new(resolve_actors: false)` builds every ref that way. The System sentinel is
constructed that way always ([ADR-0011](0011-system-sentinel-actor.md)).

**The collection resolves, the presenter reads.** `RequestPresenter#actor_refs` builds every ref a
presenter renders, unresolved; `CollectionPresenter` passes a page's worth to one `ActorResolver.call`,
and each presenter then finds its refs answered ([ADR-0032](0032-presenters-are-domain-core.md)).

`config.actor_label_strategy` chooses between `:live`, which resolves and falls back to the snapshot,
and `:snapshot`, which never resolves for a label.

## Consequences

### Positive

- A page of twenty-five requests naming three actor classes costs three queries, asserted by a
  query-counting spec.
- An old request renders whatever happened to the host's schema since.
- A host whose actors are not ActiveRecord, or live behind a service, supplies a `finder` and nothing
  else changes.

### Negative

- The approver labels in stage progress are always snapshots, while a timeline actor's label follows
  the strategy. Under `:live` the same person can read differently in the two places.
- Degrading hides misconfiguration. A typo in a registered class name renders every such actor as
  deleted rather than failing. Neither `verify!` nor a registration's `problems` checks that the class
  exists.
- `to_h` and `label` answer differently under `:live`. That is deliberate — one is the row, the other
  the view — but a caller serialising a ref has to pick the one it means.
- The memo is per object. A ref resolved in one presenter and rebuilt in another queries again;
  batching is only as good as the caller that collects the refs.
