# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Attempt do
  subject(:attempt) { change_request.attempts.create!(number: 1) }

  let(:change_request) { build_request }

  it "derives its table from the prefix" do
    expect(described_class.table_name).to eq("change_request_attempts")
  end

  # §19.13, issue I6: the request id is the idempotency key handed to the target, and needs no
  # storage. §5.6's prose once promised a column its own column list never had.
  it "carries no token column" do
    expect(described_class.column_names).not_to include("token", "idempotency_key")
  end

  describe "number" do
    it "must be at least one" do
      expect(change_request.attempts.build(number: 0)).not_to be_valid
    end

    it "is required" do
      expect(change_request.attempts.build(number: nil)).not_to be_valid
    end

    # The second lock on the claim: two processes cannot both create attempt 3 (§8).
    it "is unique per request" do
      attempt

      expect { change_request.attempts.create!(number: 1) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "is refused by the index even with validations skipped" do
      attempt
      duplicate = change_request.attempts.build(number: 1)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "may repeat across requests" do
      attempt

      expect { build_request.attempts.create!(number: 1) }.not_to raise_error
    end
  end

  describe ".next_number_for" do
    it "starts at one" do
      expect(described_class.next_number_for(change_request)).to eq(1)
    end

    # These rows are the count; there is no counter column on the request (§5.6).
    it "follows the rows that exist" do
      change_request.attempts.create!(number: 1)
      change_request.attempts.create!(number: 2)

      expect(described_class.next_number_for(change_request)).to eq(3)
    end

    it "counts only that request's attempts" do
      change_request.attempts.create!(number: 1)
      other = build_request

      expect(described_class.next_number_for(other)).to eq(1)
    end
  end

  describe "outcome" do
    it "is null while the attempt is in flight" do
      expect(attempt.outcome).to be_nil
    end

    it "is not finished while null" do
      expect(attempt).not_to be_finished
    end

    ChangeRequests::Attempt::OUTCOMES.each do |outcome|
      it "accepts #{outcome}" do
        attempt.update!(outcome: outcome)

        expect(attempt.reload.outcome).to eq(outcome)
      end

      it "answers #{outcome}?" do
        attempt.update!(outcome: outcome)

        expect(attempt.public_send(:"#{outcome}?")).to be(true)
      end
    end

    it "rejects anything else" do
      expect(change_request.attempts.build(number: 2, outcome: "nearly")).not_to be_valid
    end

    it "is finished once one is set" do
      attempt.update!(outcome: "succeeded")

      expect(attempt).to be_finished
    end
  end

  describe "scopes" do
    it "separates the finished from the in-flight" do
      change_request.attempts.create!(number: 1, outcome: "failed")
      change_request.attempts.create!(number: 2)

      expect(described_class.failed.count).to eq(1)
      expect(described_class.in_flight.count).to eq(1)
    end

    it "scopes each outcome" do
      change_request.attempts.create!(number: 1, outcome: "succeeded")
      change_request.attempts.create!(number: 2, outcome: "abandoned")

      expect(described_class.succeeded.count).to eq(1)
      expect(described_class.abandoned.count).to eq(1)
    end
  end

  # §5.6: what makes "did the outbound call happen before it blew up?" answerable. There is no
  # failure_reason on the request - the message lives here and in the execution_failed event.
  describe "the failure record" do
    it "keeps the error class, message and backtrace" do
      attempt.update!(
        outcome: "failed",
        error_class: "ArgumentError",
        error_message: "unknown keyword: :roles",
        backtrace: "app/services/members/update_roles.rb:4",
        started_at: 2.seconds.ago,
        finished_at: Time.current
      )

      expect(attempt.reload.error_class).to eq("ArgumentError")
      expect(attempt.error_message).to eq("unknown keyword: :roles")
      expect(attempt.backtrace).to include("update_roles.rb")
    end

    it "records who ran it" do
      attempt.update!(executer_type: "Admin", executer_id: "42", executer_label: "Grace (admin)")

      expect(attempt.reload.executer_label).to eq("Grace (admin)")
    end
  end

  describe "associations" do
    it "belongs to its request" do
      expect(attempt.change_request).to eq(change_request)
    end

    it "reaches the request in number order" do
      second = change_request.attempts.create!(number: 2)
      first = change_request.attempts.create!(number: 1)

      expect(change_request.reload.attempts.to_a).to eq([first, second])
    end

    it "goes when its request does" do
      attempt
      change_request.destroy

      expect(described_class.where(id: attempt.id)).to be_empty
    end
  end
end
