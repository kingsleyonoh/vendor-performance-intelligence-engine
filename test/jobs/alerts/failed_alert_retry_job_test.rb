# frozen_string_literal: true

require "test_helper"

# FailedAlertRetryJob — PRD §7. Cron job (every 30min) that re-enqueues
# `HubDispatchJob` for `risk_alerts.status='failed'` rows after a cooldown.
# Backstop for the §15 #6 invariant: every failed alert is retryable
# without manual intervention.
class Alerts::FailedAlertRetryJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @vendor = vendors(:acme_alpha)
    @score  = vendor_scores(:acme_alpha_current)
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  test "picks up failed alert older than 5 minutes — enqueues HubDispatchJob" do
    alert = create_alert(status: "failed", last_attempt_at: 10.minutes.ago, dispatch_attempts: 1)

    Alerts::FailedAlertRetryJob.new.perform

    queued = enqueued_for(Alerts::HubDispatchJob)
    assert_equal 1, queued.size
    assert_equal alert.id, queued.first[:args].first
  end

  test "skips failed alert younger than 5 minutes (cooldown)" do
    create_alert(status: "failed", last_attempt_at: 1.minute.ago, dispatch_attempts: 1)

    Alerts::FailedAlertRetryJob.new.perform

    assert_empty enqueued_for(Alerts::HubDispatchJob)
  end

  test "skips alerts at MAX_DISPATCH_ATTEMPTS" do
    cap = Alerts::FailedAlertRetryJob::MAX_DISPATCH_ATTEMPTS
    create_alert(status: "failed", last_attempt_at: 1.hour.ago, dispatch_attempts: cap)

    Alerts::FailedAlertRetryJob.new.perform

    assert_empty enqueued_for(Alerts::HubDispatchJob)
  end

  test "skips delivered alerts" do
    create_alert(status: "delivered", last_attempt_at: 1.hour.ago, dispatch_attempts: 1)

    Alerts::FailedAlertRetryJob.new.perform

    assert_empty enqueued_for(Alerts::HubDispatchJob)
  end

  test "tenant-agnostic — picks up failed alerts across multiple tenants" do
    create_alert(status: "failed", last_attempt_at: 10.minutes.ago, dispatch_attempts: 1)
    create_alert(
      status: "failed",
      last_attempt_at: 10.minutes.ago,
      dispatch_attempts: 1,
      tenant: tenants(:globex_inc_us),
      vendor: vendors(:globex_zeta),
      score: vendor_scores(:globex_zeta_current)
    )

    Alerts::FailedAlertRetryJob.new.perform

    assert_equal 2, enqueued_for(Alerts::HubDispatchJob).size,
                 "FailedAlertRetryJob is a cron — must operate cross-tenant"
  end

  test "reuses delivery_payload (PRD §15 #6) — does not regenerate" do
    payload = { event_type: "vendor.risk_band_changed", marker: "frozen-marker-xyz" }
    alert = create_alert(
      status: "failed",
      last_attempt_at: 10.minutes.ago,
      dispatch_attempts: 1,
      payload: payload
    )

    Alerts::FailedAlertRetryJob.new.perform
    assert_equal 1, enqueued_for(Alerts::HubDispatchJob).size

    # Sanity: payload column unchanged after re-enqueue.
    alert.reload
    assert_equal "frozen-marker-xyz", alert.delivery_payload["marker"]
  end

  private

  def create_alert(status:, last_attempt_at:, dispatch_attempts:, tenant: @tenant, vendor: @vendor, score: @score, payload: nil)
    alert = RiskAlert.create!(
      tenant: tenant,
      vendor: vendor,
      previous_band: "low",
      new_band: "high",
      previous_score: 20.0,
      new_score: 65.0,
      direction: "escalation",
      triggered_by_score: score.id,
      status: "pending",
      delivery_payload: payload || { event_type: "vendor.risk_band_changed" }
    )
    alert.update_columns(
      status: status,
      last_attempt_at: last_attempt_at,
      dispatch_attempts: dispatch_attempts
    )
    alert.reload
  end

  def enqueued_for(job_class)
    ActiveJob::Base.queue_adapter.enqueued_jobs.select do |j|
      (j[:job] || j["job_class"]).to_s == job_class.name
    end
  end
end
