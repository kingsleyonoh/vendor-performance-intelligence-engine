# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"
require "pg"
require_relative "e2e_test_helper"

# Shell-level E2E for the alerts API (PRD §5, §8b, §13.2). Boots a real
# Puma, registers two tenants over real HTTP, seeds a risk_alert directly
# via a PG connection (band-crossing happens via background job — bypass
# for E2E speed), then exercises GET / acknowledge / suppress / cross-tenant
# 404 over real HTTP.
class AlertsFlowE2ETest < ActiveSupport::TestCase
  include E2ETestHelper

  BASE_URL = ENV.fetch("E2E_BASE_URL", "http://127.0.0.1:3001")

  def post_json(path, body, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    headers.each { |k, v| req[k] = v }
    req.body = body.to_json
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  def get_json(path, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Get.new(uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  def register_tenant(slug_suffix)
    body = {
      slug: "e2e-a-#{slug_suffix}",
      legal_name: "E2E Alerts Test #{slug_suffix}",
      full_legal_name: "E2E Alerts Test #{slug_suffix} Ltd",
      display_name: "E2EA#{slug_suffix}",
      address: { line1: "1 Alert St", city: "Testville", country_code: "GB" },
      registration: { tax_id: "GB-A-#{slug_suffix}", company_number: "A#{slug_suffix}" },
      contact: { email: "a#{slug_suffix}@e2e.example" }
    }
    res = nil
    4.times do
      res = post_json("/api/tenants/register", body)
      break if res.code != "429"

      sleep 15
    end
    assert_equal "201", res.code, "register failed: #{res.code} #{res.body}"
    JSON.parse(res.body).fetch("api_key")
  end

  # Seed a risk_alert via a direct PG connection (the band-crossing path is
  # exhaustively covered by integration tests; this E2E focuses on the API
  # surface).
  def seed_alert(api_key:, vendor_canonical_name:)
    pg = pg_connection
    tenant_id = pg.exec_params(
      "SELECT id FROM tenants WHERE api_key_prefix = $1",
      [api_key[0, 12]]
    ).first.fetch("id")

    # Insert a vendor + score for the new tenant so the FK constraints pass.
    vendor_id = SecureRandom.uuid
    pg.exec_params(
      "INSERT INTO vendors (id, tenant_id, canonical_name, normalized_name, country_code, status, metadata, created_at, updated_at) " \
        "VALUES ($1, $2, $3, $4, $5, $6, $7, NOW(), NOW())",
      [vendor_id, tenant_id, vendor_canonical_name, vendor_canonical_name.downcase, "GB", "active", "{}"]
    )

    # Reuse an existing scoring_rule for this tenant if one exists (the
    # tenant registration auto-seeds a default rule). Otherwise insert one.
    existing = pg.exec_params("SELECT id FROM scoring_rules WHERE tenant_id = $1 LIMIT 1", [tenant_id]).first
    rule_id = existing&.fetch("id") || SecureRandom.uuid
    if existing.nil?
      pg.exec_params(
        "INSERT INTO scoring_rules (id, tenant_id, name, is_active, category_weights, signal_weight_overrides, band_thresholds, window_days, time_decay_half_life_days, created_at, updated_at) " \
          "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW(), NOW())",
        [
          rule_id, tenant_id, "E2E Rule-#{SecureRandom.hex(4)}", "t",
          '{"financial":0.35,"operational":0.10,"contractual":0.30,"integration":0.10,"transactional":0.15}',
          "{}",
          '{"low_max":30,"medium_max":60,"high_max":85}',
          90, 45
        ]
      )
    end

    score_id = SecureRandom.uuid
    pg.exec_params(
      "INSERT INTO vendor_scores (id, tenant_id, vendor_id, scoring_rules_id, composite_score, band, trend, category_scores, top_contributors, window_days, signals_considered_count, computed_at, created_at, updated_at) " \
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, NOW(), NOW(), NOW())",
      [
        score_id, tenant_id, vendor_id, rule_id, 65.0, "high", "degrading",
        '{"financial":65,"operational":65,"contractual":65,"integration":65,"transactional":65}',
        '[]', 90, 0
      ]
    )

    alert_id = SecureRandom.uuid
    payload = {
      event_type: "vendor.risk_band_changed",
      tenant: { id: tenant_id, legal_name: "E2E Frozen Legal Name" },
      vendor: { id: vendor_id, canonical_name: vendor_canonical_name },
      score:  { previous_band: "low", new_band: "high", direction: "escalation" }
    }.to_json

    pg.exec_params(
      "INSERT INTO risk_alerts (id, tenant_id, vendor_id, previous_band, new_band, previous_score, new_score, direction, triggered_by_score, status, delivery_payload, dispatch_attempts, created_at, updated_at) " \
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, NOW(), NOW())",
      [alert_id, tenant_id, vendor_id, "low", "high", 20.0, 65.0, "escalation",
       score_id, "delivered", payload, 1]
    )

    alert_id
  ensure
    pg&.close
  end

  def pg_connection
    cfg = ActiveRecord::Base.configurations.configs_for(env_name: "test").first
    PG.connect(
      host: cfg.configuration_hash[:host],
      port: cfg.configuration_hash[:port],
      dbname: cfg.configuration_hash[:database],
      user: cfg.configuration_hash[:username],
      password: cfg.configuration_hash[:password]
    )
  end

  test "alerts list/show/acknowledge/suppress + cross-tenant 404 over real HTTP" do
    suffix = Time.now.to_i.to_s
    acme_key   = register_tenant("a#{suffix}")
    globex_key = register_tenant("b#{suffix}")
    acme_headers   = { "X-API-Key" => acme_key }
    globex_headers = { "X-API-Key" => globex_key }

    alert_id = seed_alert(api_key: acme_key, vendor_canonical_name: "E2E Alert Vendor")

    # 1. GET /api/alerts → list contains it
    list_res = get_json("/api/alerts", headers: acme_headers)
    assert_equal "200", list_res.code, list_res.body
    list_ids = JSON.parse(list_res.body).fetch("alerts").map { |a| a["id"] }
    assert_includes list_ids, alert_id

    # 2. GET /api/alerts/:id
    show_res = get_json("/api/alerts/#{alert_id}", headers: acme_headers)
    assert_equal "200", show_res.code
    body = JSON.parse(show_res.body).fetch("alert")
    assert_equal alert_id, body["id"]
    assert body["delivery_payload"].is_a?(Hash)
    assert_equal "E2E Frozen Legal Name", body["delivery_payload"].dig("tenant", "legal_name")

    # 3. POST /api/alerts/:id/acknowledge
    ack_res = post_json("/api/alerts/#{alert_id}/acknowledge", {}, headers: acme_headers)
    assert_equal "200", ack_res.code, ack_res.body
    assert_equal "acknowledged", JSON.parse(ack_res.body).dig("alert", "status")

    # 4. POST /api/alerts/:id/suppress (after ack — try a fresh alert state via second alert)
    # Ack is one-shot; suppress requires a different starting state. Skip
    # the suppress step on the same alert and re-seed for a clean test.
    fresh_alert_id = seed_alert(api_key: acme_key, vendor_canonical_name: "E2E Suppress Vendor")
    until_iso = (Time.now.utc + 12 * 3600).iso8601
    sup_res = post_json("/api/alerts/#{fresh_alert_id}/suppress", { until: until_iso },
                        headers: acme_headers)
    assert_equal "200", sup_res.code, sup_res.body
    assert_equal "suppressed", JSON.parse(sup_res.body).dig("alert", "status")

    # 5. Cross-tenant 404 — globex hitting acme's alert id
    xt_res = get_json("/api/alerts/#{alert_id}", headers: globex_headers)
    assert_equal "404", xt_res.code
  end
end
