# frozen_string_literal: true

# Builds the row graph the model specs need, until M1b-4's Create command materialises it for real.
module WorkflowFixture
  def build_request(**overrides)
    ChangeRequests::Request.create!(
      {
        operation_key: "members.update_roles",
        service: "Members::UpdateRoles",
        method_name: "call",
        operation_version: "2026-09-10",
        requester_type: "User",
        requester_id: "1",
        requester_label: "Ada Lovelace",
      }.merge(overrides)
    )
  end

  def build_stage(change_request, position: 1, name: "operational", **overrides)
    change_request.stages.create!(position: position, name: name, **overrides)
  end

  def build_quorum(stage, position: 1, threshold: 1, name: "owners", **overrides)
    stage.quorums.create!(position: position, threshold: threshold, name: name, **overrides)
  end

  def build_approval(stage, actor_type: "Admin", actor_id: "42", **overrides)
    stage.approvals.create!(
      {
        change_request: stage.change_request,
        approver_type: actor_type,
        approver_id: actor_id,
        approver_label: "#{actor_type} #{actor_id}",
        decision: "approved",
        decided_at: Time.current,
      }.merge(overrides)
    )
  end
end

RSpec.configure do |config|
  config.include WorkflowFixture
end
