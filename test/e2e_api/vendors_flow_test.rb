# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"

# Shell-level E2E against a booted Puma for the Phase 1 vendor domain:
# register -> create vendor -> list -> show -> patch -> create alias ->
# pending queue -> soft-delete. Also exercises cross-tenant 404.
#
# Endpoints exercised:
#   POST   /api/tenants/register
#   GET    /api/tenants/me
#   POST   /api/vendors
#   GET    /api/vendors
#   GET    /api/vendors/:id
#   PATCH  /api/vendors/:id
#   POST   /api/vendors/:id/aliases
#   GET    /api/aliases/pending
#   DELETE /api/vendors/:id
class VendorsFlowE2ETest < ActiveSupport::TestCase
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

  def patch_json(path, body, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Patch.new(uri)
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

  def delete_json(path, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Delete.new(uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  def register_tenant(slug_suffix)
    body = {
      slug: "e2e-v-#{slug_suffix}",
      legal_name: "E2E Vendor Test #{slug_suffix}",
      full_legal_name: "E2E Vendor Test #{slug_suffix} Ltd",
      display_name: "E2EV#{slug_suffix}",
      address: { line1: "1 Vendor St", city: "Testville", country_code: "GB" },
      registration: { tax_id: "GB-V-#{slug_suffix}", company_number: "V#{slug_suffix}" },
      contact: { email: "v#{slug_suffix}@e2e.example" }
    }
    res = post_json("/api/tenants/register", body)
    assert_equal "201", res.code, "register failed: #{res.code} #{res.body}"
    JSON.parse(res.body).fetch("api_key")
  end

  test "vendors full CRUD flow + cross-tenant isolation over real HTTP" do
    suffix = Time.now.to_i.to_s
    acme_key = register_tenant("a#{suffix}")
    globex_key = register_tenant("b#{suffix}")
    acme_headers   = { "X-API-Key" => acme_key }
    globex_headers = { "X-API-Key" => globex_key }

    # 1. POST /api/vendors — create
    vendor_body = {
      vendor: {
        canonical_name: "E2E Supplier Corp",
        country_code: "DE",
        category: "hardware",
        annual_spend_cents: 500_000
      }
    }
    create_res = post_json("/api/vendors", vendor_body, headers: acme_headers)
    assert_equal "201", create_res.code, "create: #{create_res.code} #{create_res.body}"
    vendor_id = JSON.parse(create_res.body).dig("vendor", "id")
    assert vendor_id, "expected vendor id in response"

    # 2. GET /api/vendors — list includes it
    list_res = get_json("/api/vendors", headers: acme_headers)
    assert_equal "200", list_res.code
    list_names = JSON.parse(list_res.body).fetch("vendors").map { |v| v["canonical_name"] }
    assert_includes list_names, "E2E Supplier Corp"

    # 3. GET /api/vendors/:id — show
    show_res = get_json("/api/vendors/#{vendor_id}", headers: acme_headers)
    assert_equal "200", show_res.code
    assert_equal "E2E Supplier Corp", JSON.parse(show_res.body).dig("vendor", "canonical_name")

    # 4. PATCH /api/vendors/:id — update
    patch_res = patch_json(
      "/api/vendors/#{vendor_id}",
      { vendor: { category: "services" } },
      headers: acme_headers
    )
    assert_equal "200", patch_res.code
    assert_equal "services", JSON.parse(patch_res.body).dig("vendor", "category")

    # 5. POST /api/vendors/:id/aliases — manual alias, auto-confirmed
    alias_res = post_json(
      "/api/vendors/#{vendor_id}/aliases",
      { alias: { source_system: "manual", source_ref: "e2e-ref-1" } },
      headers: acme_headers
    )
    assert_equal "201", alias_res.code, alias_res.body
    alias_payload = JSON.parse(alias_res.body).fetch("alias")
    assert_equal "manual", alias_payload["source_system"]
    assert_equal true, alias_payload["is_confirmed"]

    # 5b. POST another alias that starts pending so the queue has content
    pending_alias_res = post_json(
      "/api/vendors/#{vendor_id}/aliases",
      { alias: {
          source_system: "invoice_recon",
          source_ref: "e2e-ref-p-1",
          confidence: 0.85,
          is_confirmed: false
        } },
      headers: acme_headers
    )
    assert_equal "201", pending_alias_res.code

    # 6. GET /api/aliases/pending
    pending_res = get_json("/api/aliases/pending", headers: acme_headers)
    assert_equal "200", pending_res.code
    pending_refs = JSON.parse(pending_res.body).fetch("aliases").map { |a| a["source_ref"] }
    assert_includes pending_refs, "e2e-ref-p-1"

    # 7. Cross-tenant: globex MUST NOT see acme's vendor (404, not 403/200)
    xt_res = get_json("/api/vendors/#{vendor_id}", headers: globex_headers)
    assert_equal "404", xt_res.code,
      "cross-tenant must 404, got #{xt_res.code}: #{xt_res.body}"

    # 8. DELETE /api/vendors/:id — soft delete (status=terminated)
    delete_res = delete_json("/api/vendors/#{vendor_id}", headers: acme_headers)
    assert_equal "200", delete_res.code
    assert_equal "terminated", JSON.parse(delete_res.body).dig("vendor", "status")
  end
end
