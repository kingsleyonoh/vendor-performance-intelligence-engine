# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"
require "pg"
require_relative "e2e_test_helper"

# Shell-level E2E for the reports API (PRD §5, §8b, §13.3). Boots a real
# Puma, registers a tenant over real HTTP, exercises POST/GET/download
# over real HTTP. Cross-tenant 404 is asserted for the second tenant.
class ReportsFlowE2ETest < ActiveSupport::TestCase
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

  def get_request(path, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Get.new(uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  def register_tenant(slug_suffix)
    body = {
      slug: "e2e-r-#{slug_suffix}",
      legal_name: "E2E Reports Test #{slug_suffix}",
      full_legal_name: "E2E Reports Test #{slug_suffix} Ltd",
      display_name: "E2ER#{slug_suffix}",
      address: { line1: "1 Reports St", city: "Testville", country_code: "GB" },
      registration: { tax_id: "GB-R-#{slug_suffix}", company_number: "R#{slug_suffix}" },
      contact: { email: "r#{slug_suffix}@e2e.example" }
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

  # Mark an existing report row as ready by writing render_context +
  # storage_path directly. Phase-3 ReportGeneratorJob runs in Sidekiq;
  # the E2E focuses on the API surface, so we shortcut the job.
  def mark_ready(report_id)
    pg = pg_connection
    csv_payload = "vendor_id,canonical_name,band,composite_score\n"
    pg.exec_params(
      "UPDATE vendor_reports SET status = $1, render_context = $2::jsonb, tenant_snapshot = $3::jsonb, " \
        "inline_payload = $4, generated_at = NOW(), expires_at = NOW() + INTERVAL '7 days', updated_at = NOW() " \
        "WHERE id = $5",
      ["ready", '{"schema_version":"vpi.report.v1"}', '{"id":"x"}', csv_payload, report_id]
    )
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

  test "reports POST/GET/download + cross-tenant 404 over real HTTP" do
    suffix = Time.now.to_i.to_s
    acme_key   = register_tenant("a#{suffix}")
    globex_key = register_tenant("b#{suffix}")
    acme_headers   = { "X-API-Key" => acme_key }
    globex_headers = { "X-API-Key" => globex_key }

    # 1. POST /api/reports → 202, status=queued
    create_res = post_json("/api/reports",
                           { report_type: "portfolio_risk", output_format: "csv" },
                           headers: acme_headers)
    assert_equal "202", create_res.code, create_res.body
    body = JSON.parse(create_res.body)
    report_id = body.dig("report", "id")
    assert report_id.is_a?(String) && !report_id.empty?
    assert_equal "queued", body.dig("report", "status")
    assert_equal "/api/reports/#{report_id}", body["status_url"]

    # 2. GET /api/reports → list contains the new row (queued)
    list_res = get_request("/api/reports", headers: acme_headers)
    assert_equal "200", list_res.code, list_res.body
    list_ids = JSON.parse(list_res.body).fetch("reports").map { |r| r["id"] }
    assert_includes list_ids, report_id

    # 3. GET /api/reports/:id
    show_res = get_request("/api/reports/#{report_id}", headers: acme_headers)
    assert_equal "200", show_res.code
    show_body = JSON.parse(show_res.body).fetch("report")
    assert_equal report_id, show_body["id"]
    refute show_body.key?("render_context"),
           "render_context excluded by default in show response"

    # 4. Mark the report ready directly (bypassing Sidekiq for E2E speed),
    # then GET /api/reports/:id/download streams the file.
    mark_ready(report_id)

    dl_res = get_request("/api/reports/#{report_id}/download", headers: acme_headers)
    assert_equal "200", dl_res.code, dl_res.body
    assert_match(%r{text/csv}, dl_res["Content-Type"].to_s)
    assert_includes dl_res.body.to_s, "vendor_id,canonical_name"

    # 5. Cross-tenant 404 — globex hitting acme's report id
    xt_res = get_request("/api/reports/#{report_id}", headers: globex_headers)
    assert_equal "404", xt_res.code

    xt_dl = get_request("/api/reports/#{report_id}/download", headers: globex_headers)
    assert_equal "404", xt_dl.code
  end
end
