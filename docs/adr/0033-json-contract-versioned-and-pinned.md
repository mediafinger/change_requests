# ADR-0033: Publish `as_json` as a versioned contract, held to its document and a golden file

- **Status:** Accepted
- **Date:** 2026-09-17

## Context

§11 called `as_json` public API, but nobody had written down its keys or value types. Front ends in other
languages cannot read Ruby symbols or guess which keys are optional. A contract that exists only in code
changes whenever the code does, and adopters find out from their error logs.

## Decision

- **`ChangeRequests::JsonContract`** builds the hash from a `RequestPresenter`, with a top-level integer
  `schema_version`, currently `1`. Ids are strings, timestamps ISO8601 UTC with `Z`, enums strings, labels
  translated, booleans real, and absent values `null`, never omitted. `payload` and `metadata` pass
  through verbatim.
- **`docs/06_views_and_theming.md` is the contract.** It holds a worked example and a table of every key
  with its JSON type. A spec parses both and compares them with what `as_json` produces for a fully
  populated request and a sparse one: same keys, allowed types only.
- **A golden file** (`spec/fixtures/json_contract/request.json`) pins one fully populated request, with
  time frozen and uuids normalised. `UPDATE_GOLDEN=1` regenerates it, which makes a change a deliberate
  diff in review.
- **Versioning:** adding a key keeps `schema_version`. Removing a key, renaming one or changing a value's
  type bumps it.

## Consequences

### Positive

- The document cannot drift from the code, and a contract change is visible in review.
- Consumers never branch on a missing key or a symbol.

### Negative

- Every additive change is a three-file change: code, document and golden file.
- The golden fixture freezes time, so events written in one transaction share an `occurred_at`. Their
  order then depends on PostgreSQL returning rows in insertion order, because events have no tiebreaker
  column.
- `payload_fields[].label` is never null (the humanized key), which departs from the plan's original
  example.
