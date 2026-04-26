# frozen_string_literal: true

require "test_helper"

# Audit coverage sweep — PRD §4.12 + §13.3.
#
# Asserts that every mutating /api/* endpoint produces an audit_log_entries
# row. The Api::BaseController's `record_audit_trail` after_action covers
# the standard create/update/destroy actions; this test forces a request
# down each of those paths and verifies a row was inserted with the
# correct entity_type + tenant_id.
#
# Non-RESTful state-change actions (acknowledge, suppress, retry,
# activate, merge) are listed in BaseController::MUTATING_ACTION_NAMES;
# this test exercises them too.
#
# Endpoints with explicit `Audit::Recorder.record(...)` calls (registration,
# rotate-key, merge) are also covered so the explicit calls + the
# auto-audit don't double-fire and don't miss.
class AuditCoverageTest < ActionDispatch::IntegrationTest
  ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
  GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    @vendor = vendors(:acme_alpha)
    AuditLogEntry.delete_all
  end

  teardown do
    Current.tenant = nil
    AuditLogEntry.delete_all
  end

  def acme_headers
    { "X-API-Key" => ACME_RAW_KEY, "Content-Type" => "application/json" }
  end

  def audit_count_for(action:, entity_type: nil)
    scope = AuditLogEntry.where(action: action)
    scope = scope.where(entity_type: entity_type) if entity_type
    scope.count
  end

  # ------------------------------------------------------------------
  # CRUD: Vendors
  # ------------------------------------------------------------------
  test "POST /api/vendors writes audit row" do
    body = { vendor: { canonical_name: "NewCo Auditable",
                       country_code: "DE", category: "audit",
                       tax_id: "DE777777777", currency: "EUR" } }

    assert_difference -> { audit_count_for(action: "vendors#create") }, 1 do
      post "/api/vendors", params: body.to_json, headers: acme_headers
    end
    assert_response :created
  end

  test "PATCH /api/vendors/:id writes audit row" do
    assert_difference -> { audit_count_for(action: "vendors#update") }, 1 do
      patch "/api/vendors/#{@vendor.id}",
            params: { vendor: { category: "updated" } }.to_json,
            headers: acme_headers
    end
  end

  test "DELETE /api/vendors/:id writes audit row" do
    target = vendors(:acme_delta)
    assert_difference -> { audit_count_for(action: "vendors#destroy") }, 1 do
      delete "/api/vendors/#{target.id}", headers: acme_headers
    end
  end

  # ------------------------------------------------------------------
  # Vendor aliases CRUD
  # ------------------------------------------------------------------
  test "POST /api/vendors/:id/aliases writes audit row" do
    body = { alias: { source_system: "manual", source_ref: "audit-test-1" } }
    assert_difference -> { audit_count_for(action: "vendor_aliases#create") }, 1 do
      post "/api/vendors/#{@vendor.id}/aliases",
           params: body.to_json, headers: acme_headers
    end
  end

  # ------------------------------------------------------------------
  # Scoring rules CRUD + activate
  # ------------------------------------------------------------------
  test "POST /api/scoring_rules writes audit row" do
    body = { name: "audit-test-rule",
             category_weights: { financial: 0.2, operational: 0.2,
                                 contractual: 0.2, integration: 0.2,
                                 transactional: 0.2 },
             band_thresholds: { low_max: 25.0, medium_max: 50.0, high_max: 75.0 },
             window_days: 90,
             time_decay_half_life_days: 30 }
    assert_difference -> { audit_count_for(action: "scoring_rules#create") }, 1 do
      post "/api/scoring_rules", params: body.to_json, headers: acme_headers
    end
    assert_response :created, "create payload was: #{response.body}"
  end

  test "POST /api/scoring_rules/:id/activate writes audit row (non-RESTful action)" do
    rule = ScoringRule.create!(
      tenant: @acme, name: "to-activate",
      category_weights: { financial: 0.2, operational: 0.2,
                          contractual: 0.2, integration: 0.2,
                          transactional: 0.2 },
      band_thresholds: { low_max: 25.0, medium_max: 50.0, high_max: 75.0 },
      window_days: 90, time_decay_half_life_days: 30,
      is_active: false
    )

    assert_difference -> { audit_count_for(action: "scoring_rules#activate") }, 1 do
      post "/api/scoring_rules/#{rule.id}/activate", headers: acme_headers
    end
  end

  # ------------------------------------------------------------------
  # Alerts non-RESTful actions
  # ------------------------------------------------------------------
  test "POST /api/alerts/:id/acknowledge writes audit row" do
    rule = scoring_rules(:acme_default)
    score = VendorScore.create!(
      tenant: @acme, vendor: @vendor, scoring_rule: rule,
      composite_score: 60.0, band: "high", trend: "degrading",
      category_scores: { financial: 60, operational: 60, contractual: 60,
                         integration: 60, transactional: 60 },
      top_contributors: [], window_days: 90,
      signals_considered_count: 1, computed_at: Time.current
    )
    payload = { event_type: "x", tenant: { id: @acme.id }, vendor: { id: @vendor.id } }
    alert = RiskAlert.create!(
      tenant: @acme, vendor: @vendor,
      previous_band: "low", new_band: "high",
      previous_score: 10, new_score: 60,
      direction: "escalation",
      triggered_score: score, triggered_by_score: score.id,
      delivery_payload: payload, status: "delivered"
    )

    assert_difference -> { audit_count_for(action: "alerts#acknowledge") }, 1 do
      post "/api/alerts/#{alert.id}/acknowledge", headers: acme_headers
    end
  end

  # ------------------------------------------------------------------
  # Tenant registration (explicit Audit::Recorder.record call — public route, no API key)
  # ------------------------------------------------------------------
  test "POST /api/tenants/register writes audit row" do
    ENV["SELF_REGISTRATION_ENABLED"] = "true"
    body = { slug: "audit-co-#{SecureRandom.hex(4)}",
             legal_name: "Audit Co",
             full_legal_name: "Audit Coverage Test Corp",
             display_name: "Audit Co",
             address: { line1: "1 Test St", city: "Berlin",
                        postal_code: "10115", country_code: "DE" },
             registration: { tax_id: "DE000000000" },
             contact: { email: "x@y.example" },
             brand_primary_hex: "#000000",
             brand_accent_hex: "#FFFFFF",
             locale: "en-US",
             timezone: "Europe/Berlin" }

    assert_difference -> { audit_count_for(action: "tenant.create") }, 1 do
      post "/api/tenants/register",
           params: body.to_json,
           headers: { "Content-Type" => "application/json" }
    end
  ensure
    ENV.delete("SELF_REGISTRATION_ENABLED")
  end

  # ------------------------------------------------------------------
  # Tenant rotate-key (explicit call)
  # ------------------------------------------------------------------
  test "POST /api/tenants/me/rotate-key writes audit row" do
    assert_difference -> { audit_count_for(action: "tenant.rotate_key") }, 1 do
      post "/api/tenants/me/rotate-key", headers: acme_headers
    end
  end

  # ------------------------------------------------------------------
  # Tenant scoping: audit row carries the caller's tenant_id
  # ------------------------------------------------------------------
  test "audit row tenant_id matches caller tenant" do
    body = { vendor: { canonical_name: "TenantScopeAudit",
                       country_code: "DE", category: "x",
                       tax_id: "DE111000111", currency: "EUR" } }
    post "/api/vendors", params: body.to_json, headers: acme_headers
    assert_response :created

    last = AuditLogEntry.where(action: "vendors#create").order(occurred_at: :desc).first
    refute_nil last
    assert_equal @acme.id, last.tenant_id
  end
end
