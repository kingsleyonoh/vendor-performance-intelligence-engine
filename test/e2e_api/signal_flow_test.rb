# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"

# Shell-level E2E for the signal → score lifecycle against a booted Puma.
#
# Endpoints exercised (all via real HTTP):
#   POST   /api/tenants/register
#   POST   /api/signals                       (single + batch)
#   GET    /api/vendors/:id/score/current
#   GET    /api/vendors/:id/score/history
#   GET    /api/vendors/:id/signals
#
# Cross-tenant isolation: second tenant's key MUST NOT see acme's resources
# (404 on every read).
class SignalFlowE2ETest < ActiveSupport::TestCase
  self.test_order = :sorted
  parallelize(workers: 1)

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
      slug: "e2e-s-#{slug_suffix}",
      legal_name: "E2E Signal Test #{slug_suffix}",
      full_legal_name: "E2E Signal Test #{slug_suffix} Ltd",
      display_name: "E2ES#{slug_suffix}",
      address: { line1: "1 Signal St", city: "Testville", country_code: "GB" },
      registration: { tax_id: "GB-S-#{slug_suffix}", company_number: "S#{slug_suffix}" },
      contact: { email: "s#{slug_suffix}@e2e.example" }
    }
    res = post_json("/api/tenants/register", body)
    assert_equal "201", res.code, "register failed: #{res.code} #{res.body}"
    parsed = JSON.parse(res.body)
    tenant_id = parsed.dig("tenant", "id")
    seed_scoring_rule_for(tenant_id) if tenant_id
    parsed.fetch("api_key")
  end

  # Until the pending Phase 1 [DATA] item auto-seeds a default scoring_rule
  # at tenant registration, E2E tests seed one defensively via a direct
  # SQL write on a SEPARATE connection — the main test-process connection
  # is wrapped in a transaction (transactional fixtures) that Puma cannot
  # see. A dedicated connection bypasses that transaction and commits
  # autonomously so Puma reads the rule through its own connection.
  def seed_scoring_rule_for(tenant_id)
    cfg = ActiveRecord::Base.configurations.configs_for(env_name: "test").first
    pg = PG.connect(
      host: cfg.configuration_hash[:host],
      port: cfg.configuration_hash[:port],
      dbname: cfg.configuration_hash[:database],
      user: cfg.configuration_hash[:username],
      password: cfg.configuration_hash[:password]
    )
    pg.exec_params(<<~SQL, [tenant_id])
      INSERT INTO scoring_rules (
        id, tenant_id, name, is_active,
        category_weights, band_thresholds, signal_weight_overrides,
        window_days, time_decay_half_life_days,
        created_at, updated_at, activated_at
      ) VALUES (
        gen_random_uuid(), $1, 'Default v1', TRUE,
        '{"financial":0.35,"operational":0.10,"contractual":0.30,"integration":0.10,"transactional":0.15}'::jsonb,
        '{"low_max":30,"medium_max":60,"high_max":85}'::jsonb,
        '{}'::jsonb,
        90, 45,
        NOW(), NOW(), NOW()
      )
      ON CONFLICT DO NOTHING
    SQL
  ensure
    pg&.close
  end

  def signal_payload(source_event_id, value: 0.25)
    {
      vendor_ref: {
        normalized_name: "e2e supplier co",
        tax_id: "DE-E2E-#{source_event_id}"
      },
      signal_code: "invoice.late_ratio_30d",
      source_system: "invoice_recon",
      source_event_id: source_event_id,
      value_numeric: value,
      recorded_at: Time.now.utc.iso8601
    }
  end

  test "signal ingestion → score → read endpoints over real HTTP" do
    suffix = Time.now.to_i.to_s
    acme_key = register_tenant("a#{suffix}")
    globex_key = register_tenant("b#{suffix}")
    acme_headers = { "X-API-Key" => acme_key }
    globex_headers = { "X-API-Key" => globex_key }

    # 1. POST /api/signals single → 201
    evt_single = "e2e-single-#{suffix}"
    single_res = post_json("/api/signals", signal_payload(evt_single), headers: acme_headers)
    assert_equal "201", single_res.code, "single ingest: #{single_res.code} #{single_res.body}"

    # 2. POST /api/signals batch (3) → 202
    batch_body = { signals: [
      signal_payload("e2e-batch-1-#{suffix}", value: 0.30),
      signal_payload("e2e-batch-2-#{suffix}", value: 0.35),
      signal_payload("e2e-batch-3-#{suffix}", value: 0.40)
    ] }
    batch_res = post_json("/api/signals", batch_body, headers: acme_headers)
    assert_equal "202", batch_res.code, "batch ingest: #{batch_res.code} #{batch_res.body}"
    batch_json = JSON.parse(batch_res.body)
    assert_equal 3, batch_json["accepted_count"]

    # Resolve the vendor_id from the first signal's response
    single_json = JSON.parse(single_res.body).fetch("signal")
    vendor_id = single_json["vendor_id"]
    assert vendor_id, "expected vendor_id in single signal response"

    # 3. Wait for ScoreRecomputeJob(s) to complete via Sidekiq. In the
    # default environment Sidekiq is async; we allow up to 10 seconds.
    score = nil
    deadline = Time.now + 10
    loop do
      score_res = get_json("/api/vendors/#{vendor_id}/score/current", headers: acme_headers)
      if score_res.code == "200"
        score = JSON.parse(score_res.body).fetch("score")
        break
      end
      break if Time.now > deadline
      sleep 0.5
    end

    assert score, "expected /score/current to return 200 within 10 seconds"
    assert score["band"], "expected band populated"
    assert score["composite_score"], "expected composite_score populated"

    # 4. GET /score/history → includes the latest score
    history_res = get_json("/api/vendors/#{vendor_id}/score/history", headers: acme_headers)
    assert_equal "200", history_res.code
    history = JSON.parse(history_res.body)
    assert history["scores"].any?, "expected at least 1 score in history"

    # 5. GET /signals → lists ingested signals
    signals_res = get_json("/api/vendors/#{vendor_id}/signals", headers: acme_headers)
    assert_equal "200", signals_res.code
    signals = JSON.parse(signals_res.body).fetch("signals")
    assert signals.size >= 4, "expected at least 4 signals (1 single + 3 batch), got #{signals.size}"

    # 6. Cross-tenant isolation — globex's key MUST 404 on acme's vendor.
    xt_current = get_json("/api/vendors/#{vendor_id}/score/current", headers: globex_headers)
    assert_equal "404", xt_current.code, "cross-tenant score/current must 404"

    xt_history = get_json("/api/vendors/#{vendor_id}/score/history", headers: globex_headers)
    assert_equal "404", xt_history.code, "cross-tenant score/history must 404"

    xt_signals = get_json("/api/vendors/#{vendor_id}/signals", headers: globex_headers)
    assert_equal "404", xt_signals.code, "cross-tenant signals must 404"
  end
end
