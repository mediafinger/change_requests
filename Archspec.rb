# frozen_string_literal: true

# PLAN.md §1 and §2 as executable rules. Run by `rake archspec`, and by `rake ci`.

source "lib/**/*.rb"

# app/ and lib/generators/ hold no Ruby yet. M6 and M7 add their boundaries here.

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

# §2's dependency rule, applied to the whole domain layer rather than the seven directories it
# names: every file under lib/change_requests/ except the engine is domain code.
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

# The arrow points one way. A domain file reaching into the engine would load Rails headlessly.
domain.cannot_use :engine
