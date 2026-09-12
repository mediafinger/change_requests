# ADR-0023: One way to declare a workflow

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

M1b shipped `op.approvals permissions:, required:` — one stage, one quorum, no ceremony — as the
shorthand for the common case, with the full `op.workflow` block DSL planned for M2 to express
staged, multi-quorum policies.

When both existed they wrote the same `@workflow` slot. A declaration carrying one of each silently
kept whichever came last, with no error and no warning. The two had also already drifted: the same
number was `required:` in one and `threshold:` in the other, and nothing but attention kept the next
pair of spellings from diverging too.

## Decision

`op.workflow` is the only way to declare who approves. `op.approvals` is deleted, not deprecated.

```ruby
op.workflow do |w|
  w.stage :operational, satisfied_by: :all_quorums do |q|
    q.quorum :admin,  permissions: [{ actor_type: "Admin" }], threshold: 1
    q.quorum :owners, permissions: %w(owner), threshold: 2
  end

  w.stage :director, permissions: %w(director), threshold: 1
end
```

- A stage with one counting rule takes its `permissions` and `threshold` inline; a stage with more
  takes a block. The two produce identical descriptions for the same policy, which is asserted
  rather than assumed.
- **`threshold:` everywhere.** There is no second spelling to drift from.
- **The host names every stage.** The gem invents none, so `config/locales/en.yml` ships no stage or
  quorum names at all and `name.humanize` covers everything unlisted.
- `Workflow::Builder` and `Workflow::StageBuilder` build a **description** and nothing else.
  `Commands::Create` materialises whatever it is handed, so there is one producer and one
  materialiser, not two of either.
- Declaration-time refusals for anything the database or the evaluator would otherwise refuse much
  later: a quorum nobody qualifies for, a threshold below one, an unknown `match` or `satisfied_by`,
  a duplicate stage or quorum name, a nameless stage, a stage block declaring no quorum, and a stage
  given both a block and inline keywords.

## Consequences

### Positive

- One slot, one writer. The silent-overwrite failure is not fixed, it is unreachable.
- Mistakes are refused in the initializer where they were made, naming the stage and quorum, rather
  than as a unique-index violation at creation or a request that sits pending until it expires.
- One normalisation of `permissions:` / `actor_type:` / `eligible_actors:` / `match:`, so the inline
  and block forms cannot disagree about what a quorum means.

### Negative

- Every host declaration changes. There is no deprecation path and no shim — acceptable only because
  nothing was released, and this record would read very differently otherwise.
- The common case got longer. `op.approvals permissions: %w(admin), required: 2` became a three-line
  block, and that is a real cost paid by every operation to remove an overwrite bug most hosts would
  never have hit.
- A quorum name is null when its stage holds one, and a string when it holds several, so event
  metadata carries the key sometimes and omits it otherwise. Readers of the trail have to handle
  both.
- `op.workflow` is the declarer and its reader is `workflow` with no block — a convention that
  worked because a block disambiguates, and which `op.override` then could not follow
  ([ADR-0026](0026-distinct-intent-distinct-command.md)).
