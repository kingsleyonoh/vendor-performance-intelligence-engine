# frozen_string_literal: true

require "test_helper"

# Alerts::CapturePayload — PRD §5.5. Builds the FROZEN DeliveryPayload
# stored in risk_alerts.delivery_payload. The Hub dispatcher reads
# only from this snapshot — re-renders MUST emit the value frozen at
# alert creation, even after tenant/vendor mutation.
class CapturePayloadTest < ActiveSupport::TestCase
  test "builds the full DeliveryPayload from a vendor_score" do
    score = vendor_scores(:acme_critical_score)
    payload = Alerts::CapturePayload.call(vendor_score: score)

    assert payload.is_a?(Hash), "payload must be a Hash"
    assert_includes %w[vendor.risk_band_changed vendor.risk_band_improved], payload[:event_type]
    assert payload.key?(:tenant)
    assert payload.key?(:vendor)
    assert payload.key?(:score)
    assert payload.key?(:top_contributors)
    assert payload.key?(:deep_links)
    assert payload.key?(:created_at)
  end

  test "tenant block matches Tenants::CaptureSnapshot output" do
    score = vendor_scores(:acme_critical_score)
    payload = Alerts::CapturePayload.call(vendor_score: score)
    snap = Tenants::CaptureSnapshot.call(tenants(:acme_gmbh_de).id)

    # Compare every §4.T column except snapshot_at (different timestamps
    # captured in different `Time.now.utc` calls).
    %i[id slug legal_name full_legal_name display_name address registration
       contact wordmark_url brand_primary_hex brand_accent_hex locale timezone].each do |k|
      if snap[k].nil?
        assert_nil payload[:tenant][k], "tenant.#{k} must match TenantSnapshot (both nil)"
      else
        assert_equal snap[k], payload[:tenant][k], "tenant.#{k} must match TenantSnapshot"
      end
    end
  end

  test "vendor block carries id, canonical_name, category, country_code, annual_spend, status" do
    score = vendor_scores(:acme_critical_score)
    vendor = vendors(:acme_gamma)
    payload = Alerts::CapturePayload.call(vendor_score: score)

    assert_equal vendor.id, payload[:vendor][:id]
    assert_equal vendor.canonical_name, payload[:vendor][:canonical_name]
    assert_equal vendor.category, payload[:vendor][:category]
    assert_equal vendor.country_code, payload[:vendor][:country_code]
    assert_equal vendor.status, payload[:vendor][:status]
    assert_equal vendor.annual_spend_cents, payload[:vendor][:annual_spend][:cents]
    assert_equal vendor.currency, payload[:vendor][:annual_spend][:currency]
    assert_match(/EUR/, payload[:vendor][:annual_spend][:formatted])
  end

  test "vendor block does NOT leak normalized_name (internal index key)" do
    score = vendor_scores(:acme_critical_score)
    payload = Alerts::CapturePayload.call(vendor_score: score)
    assert_not payload[:vendor].key?(:normalized_name), "normalized_name is internal — must not appear in DeliveryPayload"
  end

  test "score block matches PRD §5.5 shape" do
    score = vendor_scores(:acme_critical_score)
    payload = Alerts::CapturePayload.call(vendor_score: score)

    assert_kind_of Numeric, payload[:score][:new]
    assert_kind_of Numeric, payload[:score][:previous]
    assert_includes RiskAlert::BANDS, payload[:score][:new_band]
    assert_includes RiskAlert::BANDS, payload[:score][:previous_band]
    assert_equal score.window_days, payload[:score][:window_days]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, payload[:score][:computed_at])
  end

  test "top_contributors carries up to 5 entries with required keys" do
    score = vendor_scores(:acme_critical_score)
    payload = Alerts::CapturePayload.call(vendor_score: score)

    assert payload[:top_contributors].is_a?(Array)
    assert_operator payload[:top_contributors].length, :<=, 5
    payload[:top_contributors].each do |c|
      assert c[:signal_code], "every contributor must have a signal_code"
      assert c.key?(:contribution_pct)
    end
  end

  test "deep_links populated with absolute URLs" do
    score = vendor_scores(:acme_critical_score)
    payload = Alerts::CapturePayload.call(vendor_score: score)

    assert_match(%r{https?://}, payload[:deep_links][:vendor_detail])
    assert_includes payload[:deep_links][:vendor_detail], score.vendor_id
  end

  test "result is recursively frozen (snapshot semantics)" do
    score = vendor_scores(:acme_critical_score)
    payload = Alerts::CapturePayload.call(vendor_score: score)

    assert payload.frozen?
    assert_raises(FrozenError) { payload[:tenant][:legal_name] = "tampered" }
    assert_raises(FrozenError) { payload[:vendor][:canonical_name] = "tampered" }
    assert_raises(FrozenError) { payload[:score][:new] = 0 }
    assert_raises(FrozenError) { payload[:top_contributors] << { foo: 1 } }
  end

  test "mutating source tenant after capture does NOT change the payload (snapshot semantics)" do
    score = vendor_scores(:acme_critical_score)
    original_legal = score.tenant.legal_name
    payload = Alerts::CapturePayload.call(vendor_score: score)
    captured_legal = payload[:tenant][:legal_name]
    assert_equal original_legal, captured_legal

    # Mutate the live tenants row (skip frozen-payload — mutate the DB).
    Tenant.where(id: score.tenant_id).update_all(legal_name: "Acme RENAMED post-capture")
    score.tenant.reload
    assert_equal "Acme RENAMED post-capture", score.tenant.legal_name

    # The captured payload must STILL hold the original value — no
    # surprise re-resolution.
    assert_equal original_legal, payload[:tenant][:legal_name]
  end

  test "mutating source vendor after capture does NOT change the payload" do
    score = vendor_scores(:acme_critical_score)
    payload = Alerts::CapturePayload.call(vendor_score: score)
    captured_name = payload[:vendor][:canonical_name]

    Vendor.where(id: score.vendor_id).update_all(canonical_name: "RENAMED VENDOR LLC")
    assert_equal "RENAMED VENDOR LLC", Vendor.find(score.vendor_id).canonical_name

    assert_equal captured_name, payload[:vendor][:canonical_name]
  end

  test "globex (HIGH band) — works for both tenants" do
    score = vendor_scores(:globex_high_score)
    payload = Alerts::CapturePayload.call(vendor_score: score)

    assert_equal tenants(:globex_inc_us).legal_name, payload[:tenant][:legal_name]
    assert_equal "high", payload[:score][:new_band]
    # Tenant isolation: payload must NOT contain Acme's literal values.
    refute_includes payload.to_s, "Acme GmbH"
  end

  test "raises ArgumentError when called without a VendorScore" do
    assert_raises(ArgumentError) { Alerts::CapturePayload.call(vendor_score: "not-a-score") }
  end

  test "vendor in terminated status — still capturable (alerts can fire on legacy data)" do
    vendor = vendors(:acme_delta) # status: terminated per fixture
    # Build an ad-hoc score for the terminated vendor.
    score = VendorScore.create!(
      tenant: tenants(:acme_gmbh_de),
      vendor: vendor,
      scoring_rule: scoring_rules(:acme_default),
      composite_score: 80.0,
      band: "critical",
      trend: "degrading",
      category_scores: { financial: 30.0, operational: 30.0, contractual: 30.0, integration: 30.0, transactional: 30.0 },
      top_contributors: [],
      window_days: 90,
      signals_considered_count: 1,
      computed_at: 1.hour.ago
    )

    payload = Alerts::CapturePayload.call(vendor_score: score)
    assert_equal "terminated", payload[:vendor][:status]
    assert_equal "critical", payload[:score][:new_band]
  end

  test "no previous score — previous_band falls back to current band; direction = stable" do
    # globex_zeta has only the current score in fixtures — no history.
    # Wait, globex_high_score is on globex_zeta. Let's use a fresh
    # score on an unscored vendor to test the no-history branch.
    fresh_vendor = Vendor.create!(
      tenant: tenants(:acme_gmbh_de),
      canonical_name: "FreshCo Vendor",
      country_code: "DE",
      currency: "EUR",
      annual_spend_cents: 10_000_000,
      status: "active"
    )
    score = VendorScore.create!(
      tenant: tenants(:acme_gmbh_de),
      vendor: fresh_vendor,
      scoring_rule: scoring_rules(:acme_default),
      composite_score: 30.0,
      band: "medium",
      trend: "new",
      category_scores: { financial: 30.0, operational: 30.0, contractual: 30.0, integration: 30.0, transactional: 30.0 },
      top_contributors: [],
      window_days: 90,
      signals_considered_count: 5,
      computed_at: 1.hour.ago
    )

    payload = Alerts::CapturePayload.call(vendor_score: score)
    assert_equal "medium", payload[:score][:previous_band]
    assert_equal "stable", payload[:score][:direction]
    assert_equal "vendor.risk_band_changed", payload[:event_type] # default to changed
  end
end
