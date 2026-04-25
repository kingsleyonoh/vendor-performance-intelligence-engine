# frozen_string_literal: true

require "test_helper"

# HubDispatchJob — PRD §5.5, §7. Dispatches a frozen DeliveryPayload to the
# Notification Hub. The job MUST NOT touch tenants/vendors/vendor_scores
# directly; everything is read from `risk_alerts.delivery_payload` (PRD §15
# #12 snapshot freezing).
class Alerts::HubDispatchJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @vendor = vendors(:acme_alpha)
    @score  = vendor_scores(:acme_alpha_current)

    @captured_payloads = []
    @stub_response = { status: :sent, hub_event_id: "hub-evt-abc-123", response_code: 200 }
    install_hub_stub!
  end

  teardown do
    Ecosystem::HubClient.instance = @prev_instance if defined?(@prev_instance)
  end

  test "happy path — pending alert dispatches and stores hub_event_id" do
    alert = create_alert(status: "pending", payload: frozen_payload)

    Alerts::HubDispatchJob.new.perform(alert.id)

    alert.reload
    assert_equal "delivered", alert.status
    assert_equal "hub-evt-abc-123", alert.hub_event_id
    assert_not_nil alert.last_attempt_at
    assert_equal 1, alert.dispatch_attempts
    refute_nil @captured_payloads.first
  end

  test "snapshot freezing — payload sent matches frozen value, ignores live tenant rename (PRD §15 #12)" do
    captured_legal_name = "Acme GmbH"
    alert = create_alert(status: "pending", payload: frozen_payload(legal_name: captured_legal_name))

    # Simulate the tenant being renamed AFTER alert creation (the bug
    # class this invariant prevents).
    @tenant.update_columns(legal_name: "Renamed After Alert")

    Alerts::HubDispatchJob.new.perform(alert.id)

    sent_payload = @captured_payloads.first
    # jsonb storage stringifies hash keys on read — dig with string keys.
    actual_legal_name = sent_payload.dig("tenant", "legal_name") || sent_payload.dig(:tenant, :legal_name)
    assert_equal captured_legal_name, actual_legal_name,
                 "Hub should receive frozen legal_name from the alert payload, not the live tenant row"
    refute_equal "Renamed After Alert", actual_legal_name
  end

  test "5xx exhaustion — TransientFailure propagates so Sidekiq retries; status set to failed" do
    alert = create_alert(status: "pending", payload: frozen_payload)

    install_hub_stub!(raise_with: Ecosystem::TransientFailure.new("Hub returned 503"))

    assert_raises(Ecosystem::TransientFailure) do
      Alerts::HubDispatchJob.new.perform(alert.id)
    end

    alert.reload
    assert_equal "failed", alert.status
    assert_equal 1, alert.dispatch_attempts
    assert_not_nil alert.last_attempt_at
    assert_match(/503/, alert.last_error)
  end

  test "4xx terminal — :failed return moves alert to failed without re-raising" do
    alert = create_alert(status: "pending", payload: frozen_payload)

    install_hub_stub!(response: { status: :failed, error: "bad request: missing template", response_code: 400 })

    Alerts::HubDispatchJob.new.perform(alert.id)

    alert.reload
    assert_equal "failed", alert.status
    assert_match(/missing template/, alert.last_error)
    assert_equal 1, alert.dispatch_attempts
  end

  test "Hub disabled — :skipped marks alert dispatched (standalone-first, PRD §2.2)" do
    alert = create_alert(status: "pending", payload: frozen_payload)

    install_hub_stub!(response: { status: :skipped, reason: "Hub disabled" })

    Alerts::HubDispatchJob.new.perform(alert.id)

    alert.reload
    assert_equal "delivered", alert.status
    assert_nil alert.hub_event_id
  end

  test "circuit open — alert flagged failed, no re-raise (FailedAlertRetryJob picks up)" do
    alert = create_alert(status: "pending", payload: frozen_payload)

    install_hub_stub!(raise_with: Ecosystem::CircuitOpen.new("circuit open"))

    Alerts::HubDispatchJob.new.perform(alert.id)

    alert.reload
    assert_equal "failed", alert.status
    assert_match(/circuit/i, alert.last_error)
  end

  test "idempotency — already-dispatched alert is a no-op, does NOT re-call Hub" do
    alert = create_alert(status: "pending", payload: frozen_payload)
    alert.update_columns(status: "delivered", hub_event_id: "preexisting", dispatch_attempts: 1)

    Alerts::HubDispatchJob.new.perform(alert.id)

    alert.reload
    assert_equal "delivered", alert.status
    assert_equal "preexisting", alert.hub_event_id
    assert_equal 1, alert.dispatch_attempts
    assert_empty @captured_payloads, "Hub should NOT be called for an already-dispatched alert"
  end

  test "failed alert — retry path moves status to dispatching, then delivered on success" do
    alert = create_alert(status: "pending", payload: frozen_payload)
    alert.update_columns(status: "failed", dispatch_attempts: 1, last_error: "previous failure")

    Alerts::HubDispatchJob.new.perform(alert.id)

    alert.reload
    assert_equal "delivered", alert.status
    assert_equal 2, alert.dispatch_attempts
  end

  test "suppressed alert — skipped (status guard)" do
    alert = create_alert(status: "pending", payload: frozen_payload)
    alert.update_columns(status: "suppressed")

    Alerts::HubDispatchJob.new.perform(alert.id)

    alert.reload
    assert_equal "suppressed", alert.status
    assert_empty @captured_payloads
  end

  private

  def frozen_payload(legal_name: "Acme GmbH")
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
      score: { previous_band: "low", new_band: "high", direction: "escalation" },
      created_at: Time.now.utc.iso8601
    }
    deep_freeze(payload)
  end

  def deep_freeze(obj)
    case obj
    when Hash  then obj.each_value { |v| deep_freeze(v) }; obj.freeze
    when Array then obj.each       { |v| deep_freeze(v) }; obj.freeze
    when String then obj.freeze
    else obj
    end
  end

  def create_alert(status:, payload:)
    RiskAlert.create!(
      tenant: @tenant,
      vendor: @vendor,
      previous_band: "low",
      new_band: "high",
      previous_score: 20.0,
      new_score: 65.0,
      direction: "escalation",
      triggered_by_score: @score.id,
      status: status,
      delivery_payload: payload
    )
  end

  # Stub HubClient.instance with an object that captures the payload and
  # returns whatever `response`/`raise_with` was configured. Lets us assert
  # exactly what bytes the dispatcher would have sent (PRD §15 #12).
  def install_hub_stub!(response: nil, raise_with: nil)
    @prev_instance = Ecosystem::HubClient.instance
    captured = @captured_payloads
    resp = response || @stub_response
    stub = Object.new
    stub.define_singleton_method(:send_event) do |payload|
      captured << payload
      raise raise_with if raise_with

      resp
    end
    Ecosystem::HubClient.instance = stub
  end
end
