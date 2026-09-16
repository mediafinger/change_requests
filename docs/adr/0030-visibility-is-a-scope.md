# ADR-0030: Scope visibility with one relation, undeclared operations first

- **Status:** Accepted
- **Date:** 2026-09-16

## Context

Authorization answers "may this actor decide"; visibility answers "may this actor see the row at
all". Multi-tenant hosts need the second to be tenant-bound, single-tenant hosts need it to cost
nothing, and both need it expressible as SQL so an index page can paginate. A request whose operation
declaration was removed has no workflow, no target and no guard that would admit a decision; listing
it invites clicks that can only refuse.

## Decision

`Request.visible_to(actor)` is the one visibility scope, and it applies two rules in order:

1. **`with_declared_operation`** — undeclared requests are invisible to everyone. They remain
   reachable through `Request.undeclared` for the maintenance sweep
   ([ADR-0028](0028-sweeps-are-rake-tasks.md)).
2. **`config.visible_scope.call(scope, actor)`** — a host-supplied relation transform.

The default `visible_scope` depends on `config.tenant_for`:

- **nil** — the identity scope. Registering a `tenant_type` only records the tenant; it narrows
  nothing.
- **set** — scopes to the `(tenant_type, tenant_id)` of `tenant_for.call(actor)`. An actor whose
  tenant is `nil` sees **nothing**: `scope.none`, never the unscoped relation.

`tenant_for` also stamps the tenant on `Commands::Create` when the caller passes none, so the value a
request is written with and the value it is filtered by come from one lambda.

Show is scoped like index, and a request outside the scope is a 404, not a 403: a 403 confirms the row
exists.

## Consequences

### Positive

- Visibility is a relation, so it composes with pagination, search and the host's own scopes.
- A host that never mentions tenants pays for one `WHERE operation_key IN (...)`.
- A missing tenant fails closed.

### Negative

- Undeclared requests vanish from every listing the moment their declaration does. That is the intent,
  but a host that removes a declaration by accident discovers it through missing rows, not an error.
- `with_declared_operation` reads the live registry, so the SQL varies with the declaration set; with
  nothing declared everything open is undeclared and nothing is visible.
- Visibility and authorization are separate. A replaced `config.authorization` does not narrow what
  an actor sees, and a replaced `visible_scope` does not narrow what they may approve; a host
  changing one has to consider the other.
- The engine's controllers are not built, so the 404 rule is a contract for them and for hosts
  rendering requests today, not something the gem enforces yet.
