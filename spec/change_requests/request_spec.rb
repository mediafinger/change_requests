# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChangeRequests::Request do
  subject(:request) { described_class.create!(**attributes) }

  let(:attributes) do
    {
      operation_key: "members.update_roles",
      service: "Members::UpdateRoles",
      method_name: "call",
      operation_version: "2026-09-10",
      requester_type: "User",
      requester_id: "1",
      requester_label: "Ada Lovelace",
    }
  end

  describe "the table" do
    it "is change_requests, the one name the convention gets wrong" do
      expect(described_class.table_name).to eq("change_requests")
    end
  end

  describe "status" do
    it "defaults to pending" do
      expect(request).to be_pending
    end

    it "lists §5.8's eight" do
      expect(described_class::STATUSES)
        .to eq(%w(pending approved executing successful failed rejected canceled expired))
    end

    it "names the four that are final" do
      expect(described_class::FINAL_STATUSES).to eq(%w(successful rejected canceled expired))
    end

    it "rejects a status outside them" do
      expect(described_class.new(**attributes, status: "nearly")).not_to be_valid
    end

    it "answers a predicate per status" do
      expect(request).to be_pending
      expect(request).not_to be_approved
    end

    describe "#final?" do
      it "is false while the request can still move" do
        expect(request).not_to be_final
      end

      it "is true once it has stopped" do
        expect(described_class.new(status: "canceled")).to be_final
      end
    end
  end

  describe "scopes" do
    it "finds pending and approved requests by status" do
      request
      described_class.create!(**attributes, status: "approved")

      expect(described_class.pending.count).to eq(1)
      expect(described_class.approved.count).to eq(1)
    end

    it "counts everything not yet final as open" do
      request
      described_class.create!(**attributes, status: "executing")
      described_class.create!(**attributes, status: "canceled")

      expect(described_class.open.count).to eq(2)
    end

    it "finds overridden requests without loading an event (§8.1)" do
      request
      described_class.create!(**attributes, overridden_at: Time.current)

      expect(described_class.overridden.count).to eq(1)
    end

    describe ".expired_candidates" do
      it "finds a pending request past its expiry" do
        described_class.create!(**attributes, expires_at: 1.hour.ago)

        expect(described_class.expired_candidates.count).to eq(1)
      end

      it "leaves one that has not expired yet" do
        described_class.create!(**attributes, expires_at: 1.hour.from_now)

        expect(described_class.expired_candidates).to be_empty
      end

      # expires_at is nullable, and null never expires.
      it "leaves one with no expiry at all" do
        request

        expect(described_class.expired_candidates).to be_empty
      end

      it "leaves a request that has already finished" do
        described_class.create!(**attributes, status: "successful", expires_at: 1.hour.ago)

        expect(described_class.expired_candidates).to be_empty
      end
    end

    describe ".stuck_executions" do
      def executing_with(started_at:, outcome: nil)
        request = described_class.create!(**attributes, status: "executing")
        request.attempts.create!(number: 1, started_at: started_at, outcome: outcome)

        request
      end

      it "finds a claimed request whose attempt never finished" do
        executing_with(started_at: 2.hours.ago)

        expect(described_class.stuck_executions.count).to eq(1)
      end

      it "leaves one claimed a moment ago" do
        executing_with(started_at: 1.minute.ago)

        expect(described_class.stuck_executions).to be_empty
      end

      it "leaves one whose attempt finished, however long ago it started" do
        executing_with(started_at: 2.hours.ago, outcome: "succeeded")

        expect(described_class.stuck_executions).to be_empty
      end

      it "leaves one that is not executing" do
        request # pending, and with no attempt at all

        expect(described_class.stuck_executions).to be_empty
      end

      it "takes the threshold from its caller" do
        executing_with(started_at: 5.minutes.ago)

        expect(described_class.stuck_executions(60).count).to eq(1)
        expect(described_class.stuck_executions(3600)).to be_empty
      end

      # The scope and Guards::Reap must agree, or the sweeper hands the command rows it refuses.
      it "agrees with Guards::Reap on every request it finds and every one it does not" do
        candidates = [executing_with(started_at: 2.hours.ago),
                      executing_with(started_at: 1.minute.ago),
                      executing_with(started_at: 2.hours.ago, outcome: "failed"),
                      request]

        swept = described_class.stuck_executions.to_a
        permitted = candidates.select do |candidate|
          ChangeRequests::Guards::Reap.new(request: candidate, actor: nil).allowed?
        end

        expect(swept).to match_array(permitted)
      end
    end

    describe ".undeclared" do
      before do
        ChangeRequests.operations.define("members.update_roles") do |op|
          op.version = "1"
          op.service = "Probes::Target"
          op.workflow { |w| w.stage :approval, permissions: %w(owner) }
        end
      end

      it "finds an open request with no live declaration" do
        request
        ChangeRequests.operations.clear

        expect(described_class.undeclared.count).to eq(1)
      end

      it "leaves one whose operation is still declared" do
        request

        expect(described_class.undeclared).to be_empty
      end

      it "leaves a finished request - canceled is final, and it is already over" do
        described_class.create!(**attributes, status: "canceled")
        ChangeRequests.operations.clear

        expect(described_class.undeclared).to be_empty
      end

      # Guards::Cancel refuses a request mid-flight whether or not it is declared (Q28).
      it "leaves one whose target is executing, which the reaper clears instead" do
        described_class.create!(**attributes, status: "executing")
        ChangeRequests.operations.clear

        expect(described_class.undeclared).to be_empty
      end

      it "finds everything open when nothing at all is declared" do
        request
        described_class.create!(**attributes, status: "approved")
        ChangeRequests.operations.clear

        expect(described_class.undeclared.count).to eq(2)
      end
    end
  end

  describe "validations" do
    %i(operation_key operation_version service method_name requester_type requester_id
       requester_label).each do |attribute|
      it "requires #{attribute}" do
        expect(described_class.new(**attributes.except(attribute))).not_to be_valid
      end
    end

    it "requires a stage position of at least one" do
      expect(described_class.new(**attributes, current_stage_position: 0)).not_to be_valid
    end

    it "requires max_attempts of at least one" do
      expect(described_class.new(**attributes, max_attempts: 0)).not_to be_valid
    end
  end

  # §5.1. Each raises rather than discarding the change, which is what attr_readonly would do unless
  # the host app enabled raise_on_assign_to_attr_readonly (issue I4).
  describe "readonly attributes" do
    {
      operation_key: "other.operation",
      operation_version: "2026-01-01",
      service: "Other::Service",
      method_name: "run",
      payload: { "member_id" => 7 },
      payload_labels: { "member_id" => "Grace" },
      requester_type: "Admin",
      requester_id: "2",
      requester_label: "Someone Else",
      tenant_type: "Organization",
      tenant_id: "9",
      max_attempts: 3,
    }.each do |attribute, new_value|
      it "refuses to change #{attribute}" do
        request.public_send(:"#{attribute}=", new_value)

        expect { request.save! }.to raise_error(ChangeRequests::ReadonlyAttribute, /#{attribute}/)
      end

      it "leaves #{attribute} as it was created" do
        before = request.public_send(attribute)
        request.public_send(:"#{attribute}=", new_value)
        suppress(ChangeRequests::ReadonlyAttribute) { request.save }

        expect(request.reload.public_send(attribute)).to eq(before)
      end
    end

    it "leaves the columns that do change alone" do
      request.update!(status: "approved", executed_at: Time.current)

      expect(request.reload).to be_approved
    end
  end

  describe "the terminal-state guard" do
    ChangeRequests::Request::FINAL_STATUSES.each do |final_status|
      context "when #{final_status}" do
        subject(:request) { described_class.create!(**attributes, status: final_status) }

        it "refuses a further status change" do
          request.status = "pending"

          expect { request.save! }.to raise_error(ChangeRequests::AlreadyFinalized)
        end

        it "refuses a change to any other column too" do
          request.executer_label = "After the fact"

          expect { request.save! }.to raise_error(ChangeRequests::AlreadyFinalized)
        end

        it "leaves the row untouched" do
          request.status = "pending"
          suppress(ChangeRequests::AlreadyFinalized) { request.save }

          expect(request.reload.status).to eq(final_status)
        end
      end
    end

    # Reads status_was, so arriving at a final state is allowed and leaving one is not.
    describe "arriving at a final state" do
      ChangeRequests::Request::FINAL_STATUSES.each do |final_status|
        it "allows the transition into #{final_status}" do
          request.update!(status: final_status)

          expect(request.reload.status).to eq(final_status)
        end
      end
    end

    it "carries the request it refused" do
      request.update!(status: "canceled")
      request.executer_label = "After the fact"

      expect { request.save! }.to raise_error(ChangeRequests::AlreadyFinalized) { |error|
        expect(error.request).to eq(request)
      }
    end
  end

  # §5.5: terminal-state protection covers the request row's lifecycle columns, not the audit trail.
  # Written as SQL because the Event model arrives with M1a-7.
  describe "a finished request" do
    subject(:request) { described_class.create!(**attributes, status: "successful") }

    it "still accepts a new event" do
      expect { insert_event(request) }.not_to raise_error
    end

    it "records it against the request" do
      insert_event(request)

      expect(event_count(request)).to eq(1)
    end

    def insert_event(request)
      connection = described_class.connection

      connection.execute(<<~SQL.squish)
        INSERT INTO change_request_events
          (change_request_id, actor_type, actor_id, actor_label, kind, operation_version,
           body, occurred_at, created_at)
        VALUES
          (#{connection.quote(request.id)}, 'User', '1', 'Ada Lovelace', 'commented', '2026-09-10',
           'Post-mortem note', now(), now())
      SQL
    end

    def event_count(request)
      described_class.connection.select_value(
        "SELECT count(*) FROM change_request_events WHERE change_request_id = " \
        "#{described_class.connection.quote(request.id)}"
      )
    end
  end

  describe "optimistic locking" do
    it "raises StaleObjectError when the row moved under a stale copy" do
      other = described_class.find(request.id)
      request.update!(status: "approved")

      other.status = "canceled"

      expect { other.save! }.to raise_error(ActiveRecord::StaleObjectError)
    end

    it "increments lock_version on every save" do
      expect { request.update!(status: "approved") }.to change { request.reload.lock_version }.by(1)
    end
  end

  # Behaviour waits for the models; the wiring is asserted now so a typo does not sit here until M1a-4.
  describe "associations" do
    {
      stages: "ChangeRequests::Stage",
      approvals: "ChangeRequests::Approval",
      events: "ChangeRequests::Event",
      attempts: "ChangeRequests::Attempt",
    }.each do |name, class_name|
      it "has many #{name}" do
        reflection = described_class.reflect_on_association(name)

        expect(reflection.macro).to eq(:has_many)
        expect(reflection.class_name).to eq(class_name)
      end

      # The database cascades. A Rails-driven delete would hit Concerns::Immutable on events.
      it "leaves #{name} to the database on delete" do
        expect(described_class.reflect_on_association(name).options[:dependent]).to be_nil
      end
    end
  end

  describe "#current_stage" do
    it "looks the stage up by the position the request is on" do
      skip "ChangeRequests::Stage arrives with M1a-4" unless ChangeRequests.const_defined?(:Stage, false)

      request.stages.create!(position: 1, name: "operational")
      second = request.stages.create!(position: 2, name: "director")

      expect(request.current_stage.position).to eq(1)

      request.update!(current_stage_position: 2)

      expect(request.reload.current_stage).to eq(second)
    end
  end

  # The attempts rows *are* the count; there is no counter column (§19.12). It answers "is there an
  # attempt left", not "may this be executed" - Guards::Execute combines it with the status.
  describe "#retryable?" do
    it "is true for a request that has never been attempted" do
      expect(request).to be_retryable
    end

    it "is false once the single default attempt is spent" do
      request.attempts.create!(number: 1)

      expect(request.reload).not_to be_retryable
    end

    it "counts rows against max_attempts" do
      request = described_class.create!(**attributes, max_attempts: 3)
      2.times { |i| request.attempts.create!(number: i + 1) }

      expect(request.reload).to be_retryable

      request.attempts.create!(number: 3)

      expect(request.reload).not_to be_retryable
    end

    it "counts an attempt whatever its outcome, including one still in flight" do
      request = described_class.create!(**attributes, max_attempts: 2)
      request.attempts.create!(number: 1, outcome: "failed")
      request.attempts.create!(number: 2) # claimed, not yet finished

      expect(request.reload).not_to be_retryable
    end

    # Two reasons there is no zero case to defend against: max_attempts is `>= 1` by validation and
    # CHECK, and it is readonly after create (§5.1, §19.12).
    it "cannot be created permitting nothing" do
      expect { described_class.create!(**attributes, max_attempts: 0) }
        .to raise_error(ActiveRecord::RecordInvalid, /Max attempts/)
    end

    it "cannot be lowered afterwards" do
      expect { request.update!(max_attempts: 5) }
        .to raise_error(ChangeRequests::ReadonlyAttribute, /max_attempts/)
    end
  end
end
