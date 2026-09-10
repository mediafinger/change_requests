# Events and notifications

`change_request_events` is the audit trail. One row per transition, comment, failure or override.

## Append-only

`ChangeRequests::Event` refuses updates and deletes: both raise `ActiveRecord::ReadOnlyRecord`. The
only path that removes an event is the request's own `ON DELETE CASCADE`, which the gem never
triggers.

That is enforced in the application layer. If you want it enforced below your application as well —
so a console session or a stray `UPDATE` cannot rewrite history either — add a rule per statement:

```sql
CREATE RULE change_request_events_no_update AS
  ON UPDATE TO change_request_events DO INSTEAD NOTHING;

CREATE RULE change_request_events_no_delete AS
  ON DELETE TO change_request_events DO INSTEAD NOTHING;
```

Rules silently discard the statement. A trigger raises instead, which is louder and usually what you
want in development:

```sql
CREATE FUNCTION change_request_events_append_only() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'change_request_events is append-only';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER change_request_events_append_only
  BEFORE UPDATE OR DELETE ON change_request_events
  FOR EACH ROW EXECUTE FUNCTION change_request_events_append_only();
```

Neither ships in the install migration. `ON DELETE CASCADE` from `change_requests` is a `DELETE` on
this table, so a rule or trigger that blocks deletes also blocks the cascade — you would then have to
delete events explicitly before deleting a request. Add one only if you never delete requests.

## The System actor

Rows written by the gem itself — expiry, the stuck-execution reaper, undeclared-operation
cancellation, cooldown stage closing — carry a sentinel rather than NULL:

```ruby
ChangeRequests::SYSTEM_ACTOR  # => { type: "System", id: "system", label: "System" }
```

The actor triple is `NOT NULL` on every row, so nothing reading the trail has to branch on nil.
`Event.by_system` scopes to them; `event.system_actor?` identifies one.

The id is the word `system`, not `0`: `*_id` is a string column shared with host actor classes that
may have string primary keys, and `0` is a value one of those could legitimately hold.

## `operation_version`

Stamped on the event from the live declaration when the row is written — deliberately not the same
field as `change_requests.operation_version`, which holds the version the request was *created*
under.

They diverge when a declaration changes during a request's life, which matters most for `executed`:
dispatch resolves the operation live while the approval workflow stays frozen at creation. A request
approved under one version and executed under another is exactly the fact an audit asks about, and
joining events to the request would report the wrong answer.

It also makes the table self-contained: `change_request_events` exports alone as a complete log, with
no join required.

## Kinds

```
requested  approved  unapproved  rejected  commented  canceled
quorum_satisfied  stage_satisfied  stage_closed  overridden
execution_started  executed  execution_failed
expired  reaped  operation_undeclared
```

Enforced by an inclusion validation, with **no** CHECK constraint: later releases add kinds, and a
CHECK would make each one a migration in every host application.

## Notifications

`config.on_event` and `ActiveSupport::Notifications` arrive with M10. Both will be driven from the
single `emit` path in `Commands::Base`, after commit.
