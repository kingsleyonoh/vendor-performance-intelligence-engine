# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"
require_relative "e2e_test_helper"

# E2E for the invoice_recon ingestion path — PRD §7, §8b, §13.2.
#
# Verifies the pull-now controller now dispatches Invoice Recon sources
# (not just webhook_engine) by:
#   - registering a tenant
#   - creating an invoice_recon ingestion source
#   - calling POST /api/ingestion/sources/:id/pull_now
#   - asserting 202 + ingestion_run_id is created
#
# The actual outbound HTTP to Invoice Recon stays disabled (standalone-first):
# the booted Puma has INVOICE_RECON_ENABLED unset, so the job's client
# returns :skipped and the run completes as a successful no-op.
class InvoiceReconPullFlowE2ETest < ActiveSupport::TestCase
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

  def register_tenant(suffix)
    body = {
      slug: "e2e-irp-#{suffix}",
      legal_name: "E2E IRP #{suffix}",
      full_legal_name: "E2E IRP #{suffix} Ltd",
      display_name: "E2EIRP#{suffix}",
      address: { line1: "1 Invoice Way", city: "Invoiceville", country_code: "GB" },
      registration: { tax_id: "GB-IRP-#{suffix}", company_number: "IRP#{suffix}" },
      contact: { email: "irp#{suffix}@e2e.example" }
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

  test "pull_now on invoice_recon source dispatches the job (202)" do
    suffix = Time.now.to_i.to_s
    key = register_tenant(suffix)
    headers = { "X-API-Key" => key }

    # Create an invoice_recon source.
    create_payload = {
      source_system: "invoice_recon",
      is_enabled: true,
      connection_config: {
        base_url: "https://invoices.example.com",
        api_key_ref: "ENV:INVOICE_RECON_API_KEY"
      },
      pull_mode: "manual",
      pull_interval_minutes: 15
    }
    create_res = post_json("/api/ingestion/sources", create_payload, headers: headers)
    assert_equal "201", create_res.code, create_res.body
    source_id = JSON.parse(create_res.body).fetch("ingestion_source").fetch("id")

    # Pull-now must return 202 (NOT 422 ADAPTER_NOT_AVAILABLE, which was
    # the pre-Batch-019 response for invoice_recon).
    pull_res = post_json("/api/ingestion/sources/#{source_id}/pull_now", {}, headers: headers)
    assert_equal "202", pull_res.code,
                 "expected pull_now to dispatch invoice_recon: #{pull_res.code} #{pull_res.body}"
    pull_body = JSON.parse(pull_res.body)
    assert pull_body["ingestion_run_id"].present?
    assert_equal "queued", pull_body["status"]
  end
end
