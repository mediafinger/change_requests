# frozen_string_literal: true

module ChangeRequests
  # One execution attempt: who claimed it, when, and how it ended (§5.6).
  #
  # These rows *are* the attempt count - there is no counter column on the request. The unique
  # `(change_request_id, number)` index is the second lock on the claim: two processes cannot both
  # create attempt 3. M3a's runner writes them under T1's lock.
  #
  # No token column: the request id is the idempotency key handed to the target, and needs no storage
  # (§19.13).
  class Attempt < Record
    include Concerns::ActorColumns
    include Concerns::StringEnum

    OUTCOMES = %w(succeeded failed abandoned).freeze

    belongs_to :change_request, class_name: "ChangeRequests::Request", inverse_of: :attempts

    actor_reference :executer, optional: true

    validates :number, numericality: { only_integer: true, greater_than_or_equal_to: 1 }

    # Null while the attempt is in flight, which is most of its life - so this cannot go through
    # string_enum, which requires presence.
    validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true

    scope :succeeded, -> { where(outcome: "succeeded") }
    scope :failed, -> { where(outcome: "failed") }
    scope :abandoned, -> { where(outcome: "abandoned") }
    scope :in_flight, -> { where(outcome: nil) }

    OUTCOMES.each do |value|
      define_method(:"#{value}?") { outcome == value }
    end

    def finished? = outcome.present?

    # What the retry ceiling counts against `max_attempts` (§8).
    def self.next_number_for(change_request)
      where(change_request_id: change_request.id).count + 1
    end
  end
end
