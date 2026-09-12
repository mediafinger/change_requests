# ChangeRequests

Enforce approval workflows on any guarded action in your Rails app.

> THIS IS STILL WORK IN PROGRESS OR NOT FUNCTIONAL YET!

ChangeRequests puts an approval gate in front of any action in your Rails application. Instead of running a guarded operation immediately, you record it as a change request — the service class, the method, and its arguments — and it stays pending until one ore more other actors approve. Nothing executes until someone other than the requester has signed off.

Each request moves through a guarded lifecycle: pending, approved, successful or failed, with cancellation and comments available at any point before it reaches a final state. Every transition is a small command object that validates the actor's permissions and the current status before touching the record, so invalid transitions raise rather than silently succeed. Failed requests keep their approval and can be retried.

The engine makes no assumptions about your user model. You tell it which controller methods return the current actor and their permissions, choose which routes to mount, and it stays out of the way of the rest of your app. Reference views ship with it for a working approvals screen, and every one of them can be replaced or overridden without forking the gem.

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add change_requests
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install change_requests
```

## Usage

TODO: Write usage instructions here

## The target contract

The gem asks one thing of the code it executes on your behalf. A change-request target is a **public
singleton method** that accepts **keyword arguments only**, and whose effect is **idempotent**: running it
twice with the same payload must leave the same result as running it once.

```ruby
class Members::UpdateRoles
  def self.call(member_id:, roles:, change_request_id: nil)
    Member.find(member_id).update!(roles: roles)
  end
end
```

There is no flag to declare otherwise. A failed request keeps its approval and is retried up to
`op.max_attempts`, so a target that cannot meet the requirement must leave that at `1` — the retry ceiling
is what bounds a repeated effect, and it is the only bound the gem can actually enforce.

A target that declares `change_request_id:` receives it, stable across every attempt, which one calling an
external API can pass on as that API's own idempotency key.

`rake change_requests:verify` checks the half of this that is checkable: that every declared service
resolves, and that it answers the singleton method dispatch will call. Idempotence it cannot check, and
does not try.

[docs/05_execution_and_idempotency.md](docs/05_execution_and_idempotency.md) covers the rest: how an
execution is claimed and settled, inline against background mode, and the two maintenance tasks that
belong on a crontab.

## Architecture

The decisions behind the gem's shape — and what each one costs — are recorded as ADRs in
[docs/adr/](docs/adr/README.md).

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Maintainers and Contributors

### Issues

Bug reports and pull requests are welcome on GitHub at https://github.com/mediafinger/change_requests. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/mediafinger/change_requests/blob/main/CODE_OF_CONDUCT.md).

### Installation

After checking out the repo, run `bin/setup` and then `bundle execute rake ci` to run the **tests and rubocop**.

You can also run `bin/console` to open an irb session with the `ChangeRequests` pre-loaded that will allow you to experiment.

To build and install this gem onto your local machine, run `bundle exec rake install`.

> **Maintainers only:**
>
> To release a new version, bump the version number in `version.rb`, commit this change, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org/gems/change_requests).


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the ChangeRequests project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/mediafinger/change_requests/blob/main/CODE_OF_CONDUCT.md).
