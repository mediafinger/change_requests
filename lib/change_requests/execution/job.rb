# frozen_string_literal: true

# §8's background mode. Zeitwerk ignores this file and `ChangeRequests.load_execution_job!`
# requires it, because the gem has no ActiveJob dependency: `activejob` is a development
# dependency for the dummy application, and the domain core must load in a process that has
# never heard of it. Requiring this file without ActiveJob defines nothing at all.
#
# archspec:disable-next-line constants.forbid -- §8: the job exists only where the host has ActiveJob
if defined?(ActiveJob::Base)
  module ChangeRequests
    module Execution
      # T1 has already committed in the caller's process, so the request is visibly `executing`
      # and the attempt row is claimed. This runs T2 and T3, and nothing else.
      #
      # archspec:disable-next-line constants.forbid -- ditto, and the class cannot exist without it
      class Job < ::ActiveJob::Base
        # The two ids rather than the objects: a job argument has to survive serialisation, and the
        # attempt already carries the executer's triple, so T3 needs no actor object (§5.6).
        def perform(change_request_id, attempt_id)
          request = Request.find(change_request_id)

          Runner.finish(request: request, attempt: request.attempts.find(attempt_id))
        end
      end
    end
  end
end
