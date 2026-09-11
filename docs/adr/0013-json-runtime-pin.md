# ADR-0013: Pin `json` to `~> 2.7` as a runtime dependency

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

json 3.0 removed the positional-options form of `JSON.parse(source, options)`. ActiveSupport 8.1
still calls it that way, and json 3 is the default bundled version under Ruby 4. The result is that
**every `jsonb` read raises** `ArgumentError: wrong number of arguments (given 2, expected 1)` from
three frames inside ActiveSupport — with no hint that a gem version is the cause.

The gem stores `payload` and `payload_labels` as `jsonb`, so this is not an edge case: it breaks
reading any request at all.

## Decision

`change_requests.gemspec` declares `spec.add_dependency "json", "~> 2.7"`.

A development pin in the `Gemfile` was the first attempt and was not enough: it protects the gem's
own suite and nobody else, and it does not even cover the gem's own matrix gemfiles, which inherit
nothing from the root `Gemfile`. A runtime dependency is pulled in by the `gemspec` directive, so it
constrains the gem's suite, every matrix gemfile and every host.

## Consequences

### Positive

- A host cannot resolve this gem onto a json that breaks it.
- The constraint is declared once, where the rest of the gem's requirements live.

### Negative

- The gem constrains a dependency it does not itself use, on behalf of ActiveSupport. It is a
  workaround for someone else's incompatibility and should be removed once ActiveSupport stops
  calling `JSON.parse` positionally.
- A host that needs json 3 for another gem has a genuine conflict and no way around it.
