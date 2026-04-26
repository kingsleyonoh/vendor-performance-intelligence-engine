# frozen_string_literal: true

require "test_helper"

# Alerts::WorkflowEscalationJob — PRD §7, §13.2.
#
# Sister to HubDispatchJob — fires for HIGH/CRITICAL band alerts (PRD §6.b
# escalations). MUST read ONLY from `risk_alerts.delivery_payload` (PRD §15
# #12 snapshot freezing — same invariant as HubDispatchJob).
class Alerts::WorkflowEscalationJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @vendor = vendors(:acme_alpha)
    @score  = vendor_scores(:acme_alpha_current)

    @captured_calls = []
    @stub_response = { status: :executed, execution_id: "exec-abc-123", response_code: 200 }
    install_workflow_stub!
  end

  teardown do
    Ecosystem::WorkflowClient.instance = @prev_instance if defined?(@prev_instance)
  end

  test "HIGH alert — executes workflow, stores execution_id" do
    alert = create_alert(new_band: "high")

    Alerts::WorkflowEscalationJob.new.perform(alert.id)

    alert.reload
    assert_equal "exec-abc-123", alert.workflow_execution_id
    refute_empty @captured_calls
  end

  test "CRITICAL alert — executes workflow" do
    alert = create_alert(new_band: "critical")

    Alerts::WorkflowEscalationJob.new.perform(alert.id)

    alert.reload
    assert_equal "exec-abc-123", alert.workflow_execution_id
  end

  test "MEDIUM alert — skipped (no workflow call, no execution_id)" do
    alert = create_alert(new_band: "medium")

    Alerts::WorkflowEscalationJob.new.perform(alert.id)

    alert.reload
    assert_nil alert.workflow_execution_id
    assert_empty @captured_calls, "MEDIUM band must not trigger workflow"
  end

  test "LOW alert — skipped" do
    alert = create_alert(new_band: "low", previous_band: "medium")

    Alerts::WorkflowEscalationJob.new.perform(alert.id)

    alert.reload
    assert_nil alert.workflow_execution_id
    assert_empty @captured_calls
  end

  test "Workflow Engine disabled — :skipped, no execution_id stored" do
    alert = create_alert(new_band: "critical")

    install_workflow_stub!(response: { status: :skipped, reason: "Workflow Engine disabled" })

    Alerts::WorkflowEscalationJob.new.perform(alert.id)

    alert.reload
    assert_nil alert.workflow_execution_id
    refute_empty @captured_calls, "Job must call client (which then short-circuits internally)"
  end

  test "idempotent — alert with workflow_execution_id already set is a no-op" do
    alert = create_alert(new_band: "critical")
    alert.update_columns(workflow_execution_id: "preexisting-exec-id")

    Alerts::WorkflowEscalationJob.new.perform(alert.id)

    alert.reload
    assert_equal "preexisting-exec-id", alert.workflow_execution_id
    assert_empty @captured_calls, "Workflow must NOT be re-executed for an alert with existing execution_id"
  end

  test "5xx exhaustion — TransientFailure propagates so Sidekiq retries" do
    alert = create_alert(new_band: "critical")

    install_workflow_stub!(raise_with: Ecosystem::TransientFailure.new("Workflow returned 503"))

    assert_raises(Ecosystem::TransientFailure) do
      Alerts::WorkflowEscalationJob.new.perform(alert.id)
    end

    alert.reload
    assert_nil alert.workflow_execution_id
  end

  test "circuit open — alert untouched, no re-raise (FailedAlertRetryJob doesn't apply here; Sidekiq retries naturally)" do
    alert = create_alert(new_band: "critical")

    install_workflow_stub!(raise_with: Ecosystem::CircuitOpen.new("circuit open"))

    Alerts::WorkflowEscalationJob.new.perform(alert.id)

    alert.reload
    assert_nil alert.workflow_execution_id
  end

  test "4xx terminal — :failed return logged, no execution_id stored, no raise" do
    alert = create_alert(new_band: "high")

    install_workflow_stub!(response: { status: :failed, error: "workflow not registered", response_code: 422 })

    Alerts::WorkflowEscalationJob.new.perform(alert.id)

    alert.reload
    assert_nil alert.workflow_execution_id
  end

  test "snapshot freezing — workflow payload uses frozen alert.delivery_payload, not live tenant row" do
    captured_legal_name = "Acme GmbH"
    alert = create_alert(new_band: "critical", legal_name: captured_legal_name)

    @tenant.update_columns(legal_name: "Renamed After Alert")

    Alerts::WorkflowEscalationJob.new.perform(alert.id)

    sent_args = @captured_calls.first
    sent_payload = sent_args[:payload]
    actual_tenant = sent_payload[:tenant] || sent_payload["tenant"]
    actual_legal = actual_tenant&.dig("legal_name") || actual_tenant&.dig(:legal_name)
    assert_equal captured_legal_name, actual_legal,
                 "Workflow Engine must receive frozen tenant.legal_name from delivery_payload (PRD §15 #12)"
  end

  test "uses configurable workflow_id from ENV (default fallback)" do
    alert = create_alert(new_band: "critical")

    Alerts::WorkflowEscalationJob.new.perform(alert.id)

    sent_args = @captured_calls.first
    assert_equal ENV.fetch("WORKFLOW_ENGINE_ESCALATION_WORKFLOW_ID", "vpi-risk-escalation-default"), sent_args[:workflow_id]
  end

  private

  def create_alert(new_band:, previous_band: "low", legal_name: "Acme GmbH")
    payload = {
      event_type: "vendor.risk_band_changed",
      tenant: {
        id: @tenant.id,
        legal_name: legal_name,
        display_name: "Acme",
        full_legal_name: "Acme Procurement GmbH",
        locale: "de-DE",
        timezone: "Europe/Berlin"
      },
      vendor: { id: @vendor.id, canonical_name: @vendor.canonical_name },
      score: { previous_band: previous_band, new_band: new_band, direction: "escalation" },
      band_change: { previous: previous_band, new: new_band },
      created_at: Time.now.utc.iso8601
    }
    deep_freeze(payload)

    RiskAlert.create!(
      tenant: @tenant,
      vendor: @vendor,
      previous_band: previous_band,
      new_band: new_band,
      previous_score: 20.0,
      new_score: 80.0,
      direction: previous_band == "low" || %w[low medium].include?(previous_band) ? "escalation" : "improvement",
      triggered_by_score: @score.id,
      status: "pending",
      delivery_payload: payload
    )
  end

  def deep_freeze(obj)
    case obj
    when Hash  then obj.each_value { |v| deep_freeze(v) }; obj.freeze
    when Array then obj.each       { |v| deep_freeze(v) }; obj.freeze
    when String then obj.freeze
    else obj
    end
  end

  def install_workflow_stub!(response: nil, raise_with: nil)
    @prev_instance = Ecosystem::WorkflowClient.instance
    captured = @captured_calls
    resp = response || @stub_response
    stub = Object.new
    stub.define_singleton_method(:execute) do |workflow_id:, payload:|
      captured << { workflow_id: workflow_id, payload: payload }
      raise raise_with if raise_with

      resp
    end
    Ecosystem::WorkflowClient.instance = stub
  end
end
