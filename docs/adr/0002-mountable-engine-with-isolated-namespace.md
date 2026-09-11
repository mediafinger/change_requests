# ADR-0002: Ship the Rails layer as a mountable engine with an isolated namespace

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

The gem ships models, and will ship routes, controllers and views. Dropped into a host application
unnamespaced, those would collide with the host's own `Request`, `Approval` or `Event`, and the
gem's routes would appear at paths the host did not choose.

## Decision

`ChangeRequests::Engine` is a mountable `Rails::Engine` calling `isolate_namespace ChangeRequests`.
It is the only file in the gem that touches Rails, and Zeitwerk ignores it so that an eager load in
a headless process cannot pull Rails in ([ADR-0001](0001-headless-domain-core.md)).

`ChangeRequests.table_name_prefix` is defined on the module **before** `engine.rb` can load.
`isolate_namespace` installs its own prefix only `unless mod.respond_to?(:table_name_prefix)`, and
its version yields `change_requests_stages`; ours yields `change_request_stages`.

The engine validates the host's configuration in `config.after_initialize`, so a misconfiguration
fails the boot rather than the first request that touches the gem.

## Consequences

### Positive

- No constant, table name or route leaks into the host.
- Every table name is derived from one prefix plus the model name. Only `Request` sets a table name
  explicitly, because the convention would give it `change_request_requests`.
- Configuration errors surface at deploy time, listed all at once.

### Negative

- The prefix must stay defined ahead of the engine. It is load-order-sensitive and silently wrong if
  reordered, so a spec asserts it against a real engine boot.
- The host must mount the engine to get any of the Rails-facing features.
