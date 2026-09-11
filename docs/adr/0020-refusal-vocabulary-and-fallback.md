# ADR-0020: Ship refusal reasons as a closed vocabulary that degrades to the symbol

- **Status:** Accepted
- **Date:** 2026-09-12

## Context

A refusal has two audiences. Host code needs something stable to branch on; a person needs a
sentence. Returning a string serves the second badly and the first not at all, and translating in the
guard puts wording in the domain core — which must keep working in a process where `I18n` was never
configured ([ADR-0001](0001-headless-domain-core.md)).

## Decision

`Guards::Base::REASONS` is the closed vocabulary of refusal symbols, and the symbol is the contract.
Wording lives in `config/locales/en.yml` and nowhere else.

- `Refusal#i18n_key` is `change_requests.errors.<reason>`, falling back to the error class name
  underscored when a caller raised without a reason — so `NotApprovable` has a sentence too.
- `ChangeRequests::Translation` is the single lookup path. It checks `defined?(I18n)` and every
  caller passes a usable default, so **with no locale file loaded at all the message is the reason
  symbol**. That is asserted in the headless subprocess, where the message for `:requester` is
  literally `"requester"`.
- The engine needs no code for this: `Rails::Engine` already puts `config/locales` on
  `I18n.load_path`. Creating the directory is the whole of the wiring.
- Stage and quorum **names** are declaration identifiers in `snake_case`, not display text. They
  resolve through `change_requests.stages.<name>` / `change_requests.quorums.<name>` with
  `name.humanize` as the fallback, so a host that declares `sign_off` reads "Sign off" with no locale
  entry at all.

A spec holds the vocabulary and the locale file to each other **in both directions**: every reason
must have a translation, and every translation must correspond to a reason or to an error class that
can be raised without one. A vocabulary that only ever grows accumulates symbols nothing raises, and
a translation for a symbol nothing raises is a promise about behaviour the gem does not have.

## Consequences

### Positive

- Hosts branch on symbols and translate independently; overriding one sentence is a locale entry, not
  a monkey patch.
- The domain core never depends on a locale file existing, so nothing about i18n reaches back into
  the headless guarantee.
- A new reason cannot ship untranslated, and a dead one cannot linger, because the spec fails either
  way.

### Negative

- The reason symbols are public API and have to be versioned as carefully as the class names
  ([ADR-0012](0012-declared-error-taxonomy.md)).
- The bidirectional spec makes adding a reason a two-file change, deliberately.
- `I18n.load_path` is process-wide, so assertions about the bare-symbol fallback have to use reasons
  nothing will ever translate; written against real reasons they pass or fail depending on whether
  some other spec file booted Rails first.
