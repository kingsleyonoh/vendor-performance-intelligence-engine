# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"
require_relative "e2e_test_helper"

# E2E for /api/ingestion/* — PRD §5, §8b, §13.2.
#
# Exercises the full ingestion-management surface against a real Puma:
#   POST /api/tenants/register
#   POST /api/ingestion/sources                     (create)
#   GET  /api/ingestion/sources                     (list)
#   POST /api/ingestion/sources/:id/pull_now        (manual trigger)
#   GET  /api/ingestion/runs                        (audit ledger)
#   GET  /api/ingestion/sources/:id (cross-tenant)  (404)
class IngestionFlowE2ETest < ActiveSupport::TestCase
  include E2ETestHelper

  E2E_PURGE_EXTRAS = %w[ingestion_runs ingestion_sources].freeze

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

  def register_tenant(suffix)
    body = {
      slug: "e2e-ing-#{suffix}",
      legal_name: "E2E Ing #{suffix}",
      full_legal_name: "E2E Ing #{suffix} Ltd",
      display_name: "E2EIng#{suffix}",
      address: { line1: "1 Pull Ave", city: "Pullsville", country_code: "GB" },
      registration: { tax_id: "GB-IG-#{suffix}", company_number: "IG#{suffix}" },
      contact: { email: "ing#{suffix}@e2e.example" }
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

  test "ingestion sources + runs + pull-now flow over real HTTP" do
    suffix = Time.now.to_i.to_s
    key_a = register_tenant("a-#{suffix}")
    key_b = register_tenant("b-#{suffix}")
    headers_a = { "X-API-Key" => key_a }
    headers_b = { "X-API-Key" => key_b }

    # 1. Create webhook_engine source for tenant A.
    create_payload = {
      source_system: "webhook_engine",
      is_enabled: true,
      connection_config: {
        base_url: "https://webhooks.example.com",
        api_key_ref: "ENV:WEBHOOK_ENGINE_API_KEY"
      },
      pull_mode: "manual",
      pull_interval_minutes: 10
    }
    create_res = post_json("/api/ingestion/sources", create_payload, headers: headers_a)
    assert_equal "201", create_res.code, create_res.body
    source = JSON.parse(create_res.body).fetch("ingestion_source")
    source_id = source.fetch("id")
    assert_equal "<configured>", source.dig("connection_config", "api_key_ref"),
                 "api_key_ref must be redacted in API response"

    # 2. List sources — tenant A sees its source.
    list_res = get_json("/api/ingestion/sources", headers: headers_a)
    assert_equal "200", list_res.code
    list_body = JSON.parse(list_res.body)
    assert_equal 1, list_body.fetch("ingestion_sources").length

    # 3. Cross-tenant 404 for tenant B.
    show_b = get_json("/api/ingestion/sources/#{source_id}", headers: headers_b)
    assert_equal "404", show_b.code, "tenant B must not see tenant A's source"

    # 4. Pull-now on tenant A's webhook_engine source.
    pull_res = post_json("/api/ingestion/sources/#{source_id}/pull_now", {}, headers: headers_a)
    assert_equal "202", pull_res.code, pull_res.body
    pull_body = JSON.parse(pull_res.body)
    run_id = pull_body.fetch("ingestion_run_id")
    assert_equal "queued", pull_body["status"]

    # 5. List runs — tenant A sees the new run.
    runs_res = get_json("/api/ingestion/runs", headers: headers_a)
    assert_equal "200", runs_res.code
    runs_body = JSON.parse(runs_res.body)
    run_ids = runs_body.fetch("ingestion_runs").map { |r| r["id"] }
    assert_includes run_ids, run_id

    # 6. Cross-tenant runs are isolated.
    runs_b = get_json("/api/ingestion/runs", headers: headers_b)
    assert_equal "200", runs_b.code
    ids_b = JSON.parse(runs_b.body).fetch("ingestion_runs").map { |r| r["id"] }
    refute_includes ids_b, run_id, "tenant B must not see tenant A's runs"
  end

  test "POST source rejects raw secret in connection_config" do
    suffix = Time.now.to_i.to_s + "-raw"
    key = register_tenant(suffix)
    headers = { "X-API-Key" => key }

    bad = {
      source_system: "webhook_engine",
      is_enabled: true,
      connection_config: { base_url: "https://x.example", api_key: "leaked-raw-secret" },
      pull_mode: "manual"
    }
    res = post_json("/api/ingestion/sources", bad, headers: headers)
    assert_equal "400", res.code, "raw secret must be rejected"
    body = JSON.parse(res.body)
    assert_equal "VALIDATION_ERROR", body.dig("error", "code")
  end
end
