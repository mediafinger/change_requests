# Authorization and identity

The gem answers three questions, and keeps them separate on purpose. Most confusion about
authorization in an approval workflow comes from answering two of them in one place.

| Question | Answered by | Where |
|----------|-------------|-------|
| **Who is the actor?** | the host passes the object; the gem checks its class is registered | `config.actor_type` |
| **What may they do to this request?** | a guard, consulting an authorization policy for eligibility | `config.authorization` |
| **Which requests can they see?** | a scope | `config.visible_scope`, `Request.visible_to` |

The domain never calls a `current_*` method and never assumes one actor class. Everything below is an
explicit `actor:` argument.

## Who is the actor

Actor *classes* are registered up front; the actor *instance* is passed per call.

```ruby
ChangeRequests.configure do |config|
  config.actor_type "User" do |t|
    t.key_type    = :uuid
    t.label       = ->(user) { user.name }
    t.permissions = ->(user) { user.roles }
    t.path        = ->(user, routes) { routes.admin_user_path(user) }   # optional
    t.may_request = true
    t.may_approve = true
    t.may_execute = true
  end
end
```

**The registration is the allowlist.** An object whose class is not registered raises
`ChangeRequests::UnknownActorType` wherever it tries to enter — requesting, approving, executing — and
the stored type string is only ever compared against the registry, never `constantize`d to decide
whether it is acceptable.

`may_request`, `may_approve` and `may_execute` are **class-level** capabilities, and they hold whatever
authorization policy is configured below. A class with `may_approve = false` never approves, however
permissive a host's own policy is.

Reading an actor back gives you an `ActorRef` rather than the object:

```ruby
ref = request.requester
ref.label      # the live label if the record still exists, else the one recorded at the time
ref.deleted?   # true once the record is gone - render "(deleted)" with no link
ref.record     # the object, or nil; never raises
```

## What may they do: the default policy

`config.authorization` defaults to `ChangeRequests::Authorization::Permissions`, which matches the
actor's permission set — produced by their type's own `permissions` lambda — against the eligibility
rows a quorum declares.

Each row constrains **a permission, an actor type, or both**, and either may be absent. That gives
four shapes, worked through with three actor classes that derive their permissions differently:

```ruby
config.actor_type("User")    { |t| t.permissions = ->(user)    { user.roles } }
config.actor_type("Admin")   { |t| t.permissions = ->(admin)   { admin.roles + %w(admin) } }
config.actor_type("Manager") { |t| t.permissions = ->(manager) { manager.roles } }
```

| Row                       | Admits                                                | A `User` with `editor` | An `Admin` with no roles | A `Manager` with `editor` |
|---------------------------|--------------------------------------------------------|:---:|:---:|:---:|
| `("editor", "User")`      | Users holding `editor`                                 | yes | no  | no  |
| `("editor", nil)`         | anyone holding `editor`, whatever their class          | yes | no  | yes |
| `(nil, "Admin")`          | any Admin, whatever they hold                          | no  | yes | no  |
| `(nil, nil)`              | **refused** - a row constraining nothing is a bug, never a wildcard | — | — | — |

Two things follow. **One mechanism covers both kinds of application**: several actor classes, one class
carrying roles, or a mix of the two in one workflow. And **`Admin` and `User` never have to agree on what
a permission is** — each type's lambda produces its own set, and both are compared against the same row.

A quorum holding several rows admits an actor who satisfies **any** of them by default, or **all** of
them with `match: :all`. Named approvers — `eligible_actors:` — are OR-ed with the rows.

## What may they do: replacing the policy

`config.authorization` takes a lambda, which is how Pundit and ActionPolicy plug in. Neither is a
dependency of this gem; both are recipes.

### What your lambda receives, and what it does not

```ruby
config.authorization = ->(actor:, request:, stage:, action:) { … }
```

- **`action` is always `:approve`.** The policy answers *eligibility* — may this actor decide on this
  stage — and that is the same question whether the command asking is Approve, Reject or Cancel. Comment
  never asks: any registered actor may comment.
  A `reject?` method on your policy is never called.
- **It receives the stage, not a quorum.** A host policy is written against requests, so it is
  **stage-granular**: return `true` and the actor is eligible for *every* quorum of that stage. On an
  `all_quorums` stage an approval still counts toward exactly one of them — the lowest-position one —
  but your policy cannot choose which. If per-quorum eligibility matters, keep the default policy.

### What the gem still decides for you

Replacing the policy replaces **eligibility** and nothing else. These hold regardless:

- a class with `may_approve = false` is refused before your policy is consulted
- the requester never approves their own request, across actor classes when `actor_identity` is set
- one decision per person per stage
- a stage-three approver is told to wait on a stage-one request, not refused
- a request whose operation is no longer declared is refused by every guard but Comment, Cancel and Reap
- finished requests are refused, and nothing reopens a closed stage

### Pundit

<!-- recipe: pundit -->
```ruby
ChangeRequests.configure do |config|
  config.authorization = lambda do |actor:, request:, stage:, action:|
    Pundit.policy!(actor, request).public_send(:"#{action}?")
  end
end
```

Pundit resolves `ChangeRequests::RequestPolicy` from the request's class. Write `approve?` against the
request and the actor; it is the only rule the gem will call:

```ruby
class ChangeRequests::RequestPolicy < ApplicationPolicy
  def approve?
    user.roles.include?("member_admin") && record.tenant_id == user.organization_id.to_s
  end
end
```

### ActionPolicy

<!-- recipe: action_policy -->
```ruby
ChangeRequests.configure do |config|
  config.authorization = lambda do |actor:, request:, stage:, action:|
    ChangeRequests::RequestPolicy.new(request, user: actor).apply(:"#{action}?")
  end
end
```

```ruby
class ChangeRequests::RequestPolicy < ApplicationPolicy
  def approve?
    user.roles.include?("member_admin")
  end
end
```

### What a replaced policy does not reach

**The approver inbox will still be the eligibility rows.** `Request.awaiting_approval_from(actor)` — not
built yet, arriving with the inbox milestone — is a SQL scope over those rows, so it can be indexed and
paginated, and SQL cannot call your lambda. With a replaced policy, the inbox will show what the rows say
while the button enables on what your policy says.

If the two must agree, keep the rows authoritative: declare eligibility in the workflow and let your
policy only *narrow* it — refusing what the rows admit, never admitting what they refuse.

## Is this the same human twice

Separation of duties keys on `(type, id)` by default. That is airtight inside one actor class and **blind
across classes**: the gem cannot know that `Admin#7` and `User#99` are the same person.

```ruby
config.actor_identity = ->(actor) { actor.person_id }   # or an email, or the SSO subject
```

When set, the identity is snapshotted onto each request and each approval, and it replaces `(type, id)`
in two places: counting distinct approvers, and **the requester-cannot-approve rule**.

The second is the one that matters. Without it, a person with two accounts requests as `User#99` and
approves as `Admin#7`, and the four-eyes rule passes **silently**. That is worse than a miscounted
quorum, because it breaks the one promise an approval workflow exists to keep, and nothing in the trail
looks wrong.

Unset, behaviour is unchanged and the limitation is yours to know about.

## Which requests can they see

```ruby
config.tenant_for    = ->(actor) { actor.organization }
config.visible_scope = ->(scope, actor) { scope.where(tenant_id: actor.organization_id.to_s) }

ChangeRequests::Request.visible_to(current_user)
```

`visible_to` applies two rules, in order:

1. **A request whose operation is no longer declared is invisible to everyone.** It leaves inboxes and
   badges the moment the declaration goes, before any cleanup runs, and a custom `visible_scope` cannot
   see past this.
2. **`visible_scope` narrows what is left.**

`visible_scope` defaults to **tenant scoping when `tenant_for` is set**, and to everything otherwise. That
distinction is deliberate: registering a `tenant_type` only *records* a tenant, and an application that
passes `tenant:` explicitly without wanting visibility narrowed gets exactly that. **If you want scoping,
set `tenant_for`** — registering the type alone scopes nothing.

An actor whose `tenant_for` returns `nil` sees **nothing**, not everything.

`tenant_for` also stamps the tenant on a request created without an explicit `tenant:`, so a host with one
tenant per actor stops passing it at every call site. An explicit `tenant:` always wins.

### Index and show

Apply `visible_to` to **show as well as index**, and answer a request outside it with a **404, not a
403**: a 403 confirms the row exists, which is precisely what tenant scoping is hiding. The engine's
own controllers, when they ship, do exactly that; until then it is your controller's job.
