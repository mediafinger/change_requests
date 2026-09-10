# frozen_string_literal: true

# The architecture in PLAN.md §1 and §2, executable.
#
# The seam this file guards: a headless domain core that needs ActiveRecord and ActiveSupport and
# nothing else, with Rails confined to a single engine file. It is what makes
# `spec/integration/headless_spec.rb` pass, what lets a host use the gem from a rake task or an API,
# and what would keep a future split into `change_requests` + `change_requests-rails` a `git mv`
# rather than a rewrite.
#
# Run by `rake archspec`, and as part of `rake ci`.

source "lib/**/*.rb"

# ── The layers of §1 ──────────────────────────────────────────────────────────────────────────────
#
# `app/` and `lib/generators/` are not listed: they hold no Ruby yet. M6 and M7 add them, and this
# file is where their boundaries get written down.

component :domain, in: [
  "lib/change_requests.rb",
  "lib/change_requests/configuration.rb",
  "lib/change_requests/configuration/**/*.rb",
  "lib/change_requests/errors.rb",
  "lib/change_requests/translation.rb",
  "lib/change_requests/version.rb",
  "lib/change_requests/authorization/**/*.rb",
  "lib/change_requests/models/**/*.rb",
  "lib/change_requests/guards/**/*.rb",
  "lib/change_requests/commands/**/*.rb",
  "lib/change_requests/execution/**/*.rb",
  "lib/change_requests/presenters/**/*.rb",
]

component :engine, in: "lib/change_requests/engine.rb"

# ── The dependency rule of §2 ─────────────────────────────────────────────────────────────────────
#
# "Nothing under lib/change_requests/{models,operation,guards,commands,authorization,execution,
# presenters} may reference ActionController, ActionView, Rails, or any constant under app/."
#
# Applied to the whole domain layer rather than only those seven directories: every file under
# lib/change_requests/ except the engine is domain code, and the same rule serves all of it.
domain.cannot_reference_constants "Rails",
                                  "ActionController",
                                  "ActionView",
                                  "ActionDispatch",
                                  "ActiveJob",
                                  because: "the domain core must load and run with no Rails at " \
                                           "all - from a job, a console, an API or a rake task " \
                                           "(§1). ActiveJob is optional even where it is used: " \
                                           "§8's background execution is defined only when the " \
                                           "host has it."

# The engine is the Rails integration layer, so it may know about Rails - but the arrow only points
# one way. The domain must never reach back into it, or requiring the gem headlessly would load the
# very file that requires Rails.
domain.cannot_use :engine
