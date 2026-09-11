# ADR-0010: Require every operation to be declared in a registry

- **Status:** Accepted
- **Date:** 2026-09-11

## Context

Execution eventually has to turn a stored `operation_key` into a real method call. Resolving that
from the strings on the request row means `constantize` plus `public_send` on data, which turns any
endpoint that can write a row into remote code execution.

The related question is where approval policy comes from. If the caller passes thresholds and
permissions to `request!`, then policy is caller input, and every call site can get it wrong.

## Decision

A host declares its operations up front:

```ruby
ChangeRequests.operations.define "members.update_roles" do |op|
  op.version = "2026-09-11"
  op.service = "Members::UpdateRoles"
  op.approvals permissions: %w(member_admin), required: 2
end
```

- The registry is the **dispatch allowlist**. Execution resolves `operation_key → (service,
  method_name)` from the declaration, never from the stored strings, which are audit data only.
- **Approval policy comes from the declaration**, so every call that raises a request is identical
  no matter how elaborate the workflow is.
- The resolved workflow is **frozen onto the request at creation** ([ADR-0008](0008-staged-multi-quorum-schema.md)).
  Editing an operation never reaches a request already in flight.
- `op.version` is mandatory and is validated at declaration time, so the initializer's own line
  number reports the mistake.
- `operations[key]` returns **nil** rather than raising. An undeclared operation is a refusal each
  guard words for itself — commenting on a stranded request stays open, everything else does not.

`op.approvals` *describes* a workflow; creating a request is what materialises it into rows.

## Consequences

### Positive

- A stored string never reaches `constantize`, so the hole stays closed even if a careless endpoint
  lets someone write a row.
- What a request will invoke is legible from the row itself, not only from live configuration.
- Removing a declaration is reversible: the requests it strands refuse and become invisible, and
  nothing is destroyed until someone runs the cleanup task deliberately.

### Negative

- Hosts must declare operations before using them. This is the one thing the gem asks that the
  obvious alternatives do not.
- The registry is process-global mutable state, which the test suite has to isolate per example.
- Today the registry carries the declaration attributes and the `op.approvals` shorthand only; the
  full workflow DSL, boot-time verification and `ChangeRequests.request!` arrive with a later
  milestone.
