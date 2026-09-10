# frozen_string_literal: true

module ChangeRequests
  # One step of a request's workflow. Stages run in order; parallelism within a step is several
  # quorums in one stage (§5.2). Materialised from the operation at creation and never edited.
  class Stage < Record
    include Concerns::StringEnum
    include Concerns::ReadonlyAttributes

    STATUSES = %w(pending satisfied closed rejected).freeze
    SATISFIED_BY = %w(any_quorum all_quorums).freeze

    # snake_case declaration identifier, not display text: carried verbatim into event metadata and
    # test matchers, and stable across workflow edits in a way `position` is not (§5.9).
    NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/

    string_enum :status, STATUSES

    readonly_after_create :change_request_id, :position, :name, :satisfied_by

    belongs_to :change_request, class_name: "ChangeRequests::Request", inverse_of: :stages

    has_many :quorums, -> { order(:position) },
             class_name: "ChangeRequests::Quorum",
             foreign_key: :change_request_stage_id,
             inverse_of: :stage
    has_many :approvals, class_name: "ChangeRequests::Approval",
                         foreign_key: :change_request_stage_id,
                         inverse_of: :stage

    validates :satisfied_by, inclusion: { in: SATISFIED_BY }
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 1 },
                         uniqueness: { scope: :change_request_id }
    validates :name, presence: true,
                     format: { with: NAME_FORMAT },
                     uniqueness: { scope: :change_request_id }

    def any_quorum? = satisfied_by == "any_quorum"
    def all_quorums? = satisfied_by == "all_quorums"

    # Still accepting decisions. A closed stage is immutable and a rejected one stopped the request.
    def open? = pending? || satisfied?

    # Display text, resolved separately from the identifier (§5.9).
    def label
      Translation.translate("change_requests.stages.#{name}", default: name.to_s.humanize)
    end
  end
end
