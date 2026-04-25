# frozen_string_literal: true

require "test_helper"

# Band-crossing → alert pipeline (PRD §5, §7, §13.2). Wires
# `Scoring::CompositeScorer` band detection (via ScoreRecomputeJob's
# `band_crossing_hook`) → `Alerts::Dispatcher.on_band_crossing` →
# `Alerts::CapturePayload` → insert risk_alert + enqueue HubDispatchJob.
class BandCrossingAlertTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @vendor = vendors(:acme_alpha)
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    RiskAlert.where(tenant_id: @tenant.id, vendor_id: @vendor.id).delete_all
  end

  test "LOW → MEDIUM (escalation): creates alert + enqueues HubDispatchJob" do
    previous_score = create_score(band: "low", composite: 20.0, computed_at: 2.hours.ago)
    new_score      = create_score(band: "medium", composite: 45.0, computed_at: 1.hour.ago)

    assert_difference -> { RiskAlert.count }, +1 do
      Alerts::Dispatcher.on_band_crossing(score: new_score, previous_band: previous_score.band)
    end
    alert = RiskAlert.order(created_at: :desc).first
    assert_equal "pending", alert.status
    assert_equal "low", alert.previous_band
    assert_equal "medium", alert.new_band
    assert_equal "escalation", alert.direction
    assert alert.delivery_payload.is_a?(Hash)

    queued = ActiveJob::Base.queue_adapter.enqueued_jobs.select do |j|
      (j[:job] || j["job_class"]).to_s == "Alerts::HubDispatchJob"
    end
    assert_equal 1, queued.size
    assert_equal alert.id, queued.first[:args].first
  end

  test "MEDIUM → HIGH (escalation): creates alert" do
    prev = create_score(band: "medium", composite: 45.0, computed_at: 2.hours.ago)
    nu   = create_score(band: "high", composite: 70.0, computed_at: 1.hour.ago)

    assert_difference -> { RiskAlert.count }, +1 do
      Alerts::Dispatcher.on_band_crossing(score: nu, previous_band: prev.band)
    end
    assert_equal "escalation", RiskAlert.last.direction
  end

  test "HIGH → CRITICAL (escalation): creates alert" do
    prev = create_score(band: "high", composite: 70.0, computed_at: 2.hours.ago)
    nu   = create_score(band: "critical", composite: 90.0, computed_at: 1.hour.ago)

    assert_difference -> { RiskAlert.count }, +1 do
      Alerts::Dispatcher.on_band_crossing(score: nu, previous_band: prev.band)
    end
    assert_equal "escalation", RiskAlert.last.direction
  end

  test "CRITICAL → HIGH (improvement): creates alert with direction=improvement" do
    prev = create_score(band: "critical", composite: 90.0, computed_at: 2.hours.ago)
    nu   = create_score(band: "high", composite: 70.0, computed_at: 1.hour.ago)

    assert_difference -> { RiskAlert.count }, +1 do
      Alerts::Dispatcher.on_band_crossing(score: nu, previous_band: prev.band)
    end
    assert_equal "improvement", RiskAlert.last.direction
  end

  test "no band change: no alert created" do
    prev = create_score(band: "low", composite: 15.0, computed_at: 2.hours.ago)
    nu   = create_score(band: "low", composite: 18.0, computed_at: 1.hour.ago)

    assert_no_difference -> { RiskAlert.count } do
      Alerts::Dispatcher.on_band_crossing(score: nu, previous_band: prev.band)
    end
  end

  test "first score (no previous band): no alert created" do
    nu = create_score(band: "high", composite: 70.0, computed_at: 1.hour.ago)

    assert_no_difference -> { RiskAlert.count } do
      Alerts::Dispatcher.on_band_crossing(score: nu, previous_band: nil)
    end
  end

  test "dedup within ALERT_DEDUP_WINDOW_HOURS: only one alert per crossing within window" do
    prev = create_score(band: "low", composite: 20.0, computed_at: 3.hours.ago)
    nu1  = create_score(band: "high", composite: 70.0, computed_at: 2.hours.ago)
    nu2  = create_score(band: "critical", composite: 90.0, computed_at: 1.hour.ago)

    Alerts::Dispatcher.on_band_crossing(score: nu1, previous_band: prev.band)
    assert_equal 1, RiskAlert.where(vendor_id: @vendor.id).count

    # Within dedup window — should suppress.
    Alerts::Dispatcher.on_band_crossing(score: nu2, previous_band: nu1.band)
    assert_equal 1, RiskAlert.where(vendor_id: @vendor.id).count,
                 "second crossing within ALERT_DEDUP_WINDOW_HOURS must be suppressed"
  end

  test "snapshot capture: alert payload binds to tenant.legal_name AT capture, not later mutations" do
    captured = "Acme GmbH"
    @tenant.update_columns(legal_name: captured)
    prev = create_score(band: "low", composite: 20.0, computed_at: 2.hours.ago)
    nu   = create_score(band: "high", composite: 70.0, computed_at: 1.hour.ago)
    Alerts::Dispatcher.on_band_crossing(score: nu, previous_band: prev.band)
    alert = RiskAlert.last

    @tenant.update_columns(legal_name: "Renamed Co After Alert")

    assert_equal captured, alert.delivery_payload.dig("tenant", "legal_name")
  end

  private

  def create_score(band:, composite:, computed_at:)
    VendorScore.create!(
      tenant: @tenant,
      vendor: @vendor,
      scoring_rules_id: scoring_rules(:acme_default).id,
      composite_score: composite,
      band: band,
      trend: "stable",
      category_scores: { financial: composite, operational: composite, contractual: composite,
                         integration: composite, transactional: composite },
      top_contributors: [
        { "signal_code" => "invoice.late_ratio_30d", "category" => "financial",
          "contribution" => 12.5, "value" => 0.05, "direction" => "higher_is_worse" }
      ],
      window_days: 90,
      signals_considered_count: 5,
      computed_at: computed_at
    )
  end
end
