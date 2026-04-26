# frozen_string_literal: true

require "test_helper"

# Verify each of the 5 PostHog event callsites fires Analytics::Event.track
# with the correct event name + tenant context (PRD §10b).
#
# Events:
#   1. vendor_viewed         → VendorsController#show
#   2. alert_acknowledged    → AlertsController#acknowledge
#   3. scoring_rule_activated → Api::ScoringRulesController#activate
#   4. report_generated      → Reports::ReportGeneratorJob (on success)
#   5. api_key_rotated       → Api::Tenants::RotateKeyController#create
#
# We capture invocations via a process-wide test_capture array on the
# Analytics::Event class so we don't depend on Minitest::Mock's stub on
# arbitrary classes. This is a deliberate seam — see lib/analytics/event.rb.
class AnalyticsCallsitesTest < ActionDispatch::IntegrationTest
  setup do
    Analytics::Event.test_capture!
  end

  teardown do
    Analytics::Event.test_capture_off!
  end

  test "VendorsController#show fires vendor_viewed event" do
    user = users(:admin)
    vendor = vendors(:acme_alpha)
    post session_url, params: { email_address: user.email_address, password: "password123" }

    get vendor_url(vendor)

    matching = Analytics::Event.captured.select { |a| a[:event] == "vendor_viewed" }
    refute_empty matching, "Expected vendor_viewed event to fire on vendor#show"
    assert_equal vendor.id, matching.first[:properties][:vendor_id]
    assert_equal vendor.tenant_id, matching.first[:tenant_id]
  end

  test "AlertsController#acknowledge fires alert_acknowledged event" do
    user = users(:admin)
    tenant = tenants(:acme_gmbh_de)
    vendor = vendors(:acme_alpha)
    rule = scoring_rules(:acme_default)
    score = VendorScore.create!(
      tenant: tenant, vendor: vendor,
      composite_score: 30.0, band: "high", trend: "stable",
      category_scores: { financial: 30, operational: 30, contractual: 30, integration: 30, transactional: 30 },
      top_contributors: [],
      window_days: 90, scoring_rule: rule, computed_at: Time.now.utc
    )
    alert = RiskAlert.create!(
      tenant: tenant, vendor: vendor,
      previous_band: "low", new_band: "high",
      previous_score: 20.0, new_score: 65.0,
      direction: "escalation",
      triggered_by_score: score.id, status: "delivered",
      delivery_payload: { event_type: "vendor.risk_band_changed", tenant: { id: tenant.id } }
    )
    post session_url, params: { email_address: user.email_address, password: "password123" }

    post acknowledge_alert_url(alert)

    matching = Analytics::Event.captured.select { |a| a[:event] == "alert_acknowledged" }
    refute_empty matching
    assert_equal alert.id, matching.first[:properties][:alert_id]
    assert_equal alert.tenant_id, matching.first[:tenant_id]
  end

  test "Api::ScoringRulesController#activate fires scoring_rule_activated event" do
    tenant = tenants(:acme_gmbh_de)
    rule = ScoringRule.create!(
      tenant: tenant,
      name: "Draft v2",
      is_active: false,
      category_weights: { financial: 0.4, operational: 0.2, contractual: 0.2, integration: 0.1, transactional: 0.1 },
      signal_weight_overrides: {},
      band_thresholds: { low_max: 25.0, medium_max: 50.0, high_max: 75.0 },
      window_days: 90,
      time_decay_half_life_days: 45
    )

    post "/api/scoring_rules/#{rule.id}/activate",
      headers: { "X-API-Key" => api_key_for(tenant) }

    matching = Analytics::Event.captured.select { |a| a[:event] == "scoring_rule_activated" }
    refute_empty matching, "Expected scoring_rule_activated event"
    assert_equal rule.id, matching.first[:properties][:scoring_rule_id]
    assert_equal tenant.id, matching.first[:tenant_id]
  end

  test "Api::Tenants::RotateKeyController#create fires api_key_rotated event" do
    tenant = tenants(:acme_gmbh_de)

    post "/api/tenants/me/rotate-key",
      headers: { "X-API-Key" => api_key_for(tenant) }

    matching = Analytics::Event.captured.select { |a| a[:event] == "api_key_rotated" }
    refute_empty matching, "Expected api_key_rotated event"
    assert_equal tenant.id, matching.first[:tenant_id]
  end

  test "Reports::ReportGeneratorJob fires report_generated on ready" do
    tenant = tenants(:acme_gmbh_de)
    vendor = vendors(:acme_alpha)
    rule = scoring_rules(:acme_default)
    score = VendorScore.create!(
      tenant: tenant,
      vendor: vendor,
      composite_score: 72.0,
      band: "medium",
      trend: "stable",
      category_scores: { financial: 70, operational: 71, contractual: 75, integration: 70, transactional: 70 },
      top_contributors: [],
      window_days: 90,
      scoring_rule: rule,
      computed_at: Time.now.utc
    )
    report = VendorReport.create!(
      tenant: tenant,
      vendor: vendor,
      report_type: "vendor_scorecard",
      output_format: "pdf",
      status: "queued",
      parameters: { vendor_id: vendor.id }
    )

    Reports::ReportGeneratorJob.new.perform(report.id)

    matching = Analytics::Event.captured.select { |a| a[:event] == "report_generated" }
    refute_empty matching, "Expected report_generated event from job"
    assert_equal report.id, matching.first[:properties][:report_id]
    assert_equal tenant.id, matching.first[:tenant_id]
  end

  private

  # Generate a fresh API key for a fixture tenant.
  def api_key_for(tenant)
    key = ::Tenants::ApiKeyGenerator.generate
    tenant.update!(api_key_hash: key.api_key_hash, api_key_prefix: key.api_key_prefix)
    ::Cache::TenantCache.delete(key.api_key_prefix) if defined?(::Cache::TenantCache)
    key.raw_key
  end
end
