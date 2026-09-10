# frozen_string_literal: true

# Mounting the UI is opt-in, and there is nothing to mount yet: controllers and views arrive with M6,
# and `config.routes` (§10) decides which actions a host draws.
#
# The file exists from M0-5 so the engine has the route set Rails expects, and so the packaging spec
# (§15.4) has something to assert is shipped inside the gem.
ChangeRequests::Engine.routes.draw do
  # Intentionally empty until M6.
end
