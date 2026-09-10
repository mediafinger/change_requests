# frozen_string_literal: true

module ChangeRequests
  # One counting rule inside a stage: a threshold plus an eligibility set. Satisfied when `threshold`
  # distinct eligible actors have approved (§5.3).
  #
  # The threshold lives here rather than on the stage because one integer per stage cannot express
  # "one Admin *or* two Owners". There is no `rule` column - counting approvals is the only rule.
  class Quorum < Record
    include Concerns::StringEnum
    include Concerns::ReadonlyAttributes

    STATUSES = %w(pending satisfied).freeze
    PERMISSION_MATCHES = %w(any all).freeze

    NAME_FORMAT = Stage::NAME_FORMAT

    string_enum :status, STATUSES

    readonly_after_create :change_request_stage_id, :position, :name, :threshold, :permission_match

    belongs_to :stage, class_name: "ChangeRequests::Stage",
                       foreign_key: :change_request_stage_id,
                       inverse_of: :quorums

    validates :permission_match, inclusion: { in: PERMISSION_MATCHES }
    validates :threshold, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 1 },
                         uniqueness: { scope: :change_request_stage_id }

    # Null when the stage holds exactly one quorum - the `op.approvals` shorthand - because "which
    # quorum" is then not a meaningful question (§5.9).
    validates :name, format: { with: NAME_FORMAT }, allow_nil: true
    validates :name, uniqueness: { scope: :change_request_stage_id }, allow_nil: true

    def any_match? = permission_match == "any"
    def all_match? = permission_match == "all"

    # A nameless quorum has no display text of its own; the stage's label is the honest answer.
    def label
      return stage.label if name.blank?

      Translation.translate("change_requests.quorums.#{name}", default: name.humanize)
    end
  end
end
