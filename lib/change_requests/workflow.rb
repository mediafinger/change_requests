# frozen_string_literal: true

module ChangeRequests
  # What a request against an operation will materialise into: ordered stages, each holding one or
  # more quorums (§5.2, §5.3).
  #
  # A description, not rows. `Commands::Create` walks it once, at creation, and the rows it writes
  # are the frozen snapshot - editing an operation afterwards never reaches an in-flight request
  # (§6.12 point 4).
  class Workflow
    # The declaration-side vocabulary of change_request_stages.satisfied_by, as
    # Configuration::PERMISSION_MATCHES is for the quorum column (§5.2).
    SATISFIED_BY = %i(any_quorum all_quorums).freeze

    attr_reader :stages

    def initialize(stages = [])
      @stages = stages
    end

    def empty?
      stages.empty?
    end
  end
end
