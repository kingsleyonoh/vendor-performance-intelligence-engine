# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"
require "pg"
require_relative "e2e_test_helper"

# Shell-level E2E for the audit log read API (PRD §5, §8b, §13.3). Boots
# a real Puma, registers two tenants over real HTTP, seeds rows directly
# into the audit_log_entries table (insert-only model — no public POST
# endpoint), then exercises GET /api/audit-log + /api/audit-log/:id.
#
# Asserts:
#   - 200 happy path with tenant-scoped slice
#   - 401 without X-API-Key
#   - 404 cross-tenant
class AuditLogFlowE2ETest < ActiveSupport::TestCase
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
      slug: "e2e-a-#{slug_suffix}",
      legal_name: "E2E Audit Test #{slug_suffix}",
      full_legal_name: "E2E Audit Test #{slug_suffix} Ltd",
      display_name: "E2EA#{slug_suffix}",
      address: { line1: "1 Audit St", city: "Testville", country_code: "GB" },
      registration: { tax_id: "GB-A-#{slug_suffix}", company_number: "A#{slug_suffix}" },
      contact: { email: "a#{slug_suffix}@e2e.example" }
    }
    res = nil
    # 5/min/IP rate limit — total worst case wait ~60s = 4×15s. Five
    # registrations in a single test order (this test plus other E2E
    # tests sharing the run) can saturate the bucket; hold long enough
    # to let it refill twice.
    12.times do
      res = post_json("/api/tenants/register", body)
      break if res.code != "429"

      sleep 15
    end
    assert_equal "201", res.code, "register failed: #{res.code} #{res.body}"
    JSON.parse(res.body)
  end

  def seed_audit_via_pg(tenant_id:, action:, entity_id: SecureRandom.uuid)
    pg = pg_connection
    pg.exec_params(
      "INSERT INTO audit_log_entries (id, tenant_id, actor_type, actor_id, action, " \
        "entity_type, entity_id, occurred_at, created_at, updated_at) " \
        "VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, $6, NOW(), NOW(), NOW()) RETURNING id",
      [tenant_id, "Tenant", tenant_id, action, "Vendor", entity_id]
    ).first["id"]
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

  test "audit log E2E happy path + cross-tenant 404 + 401" do
    suffix1 = SecureRandom.hex(3)
    suffix2 = SecureRandom.hex(3)
    resp1 = register_tenant(suffix1)
    resp2 = register_tenant(suffix2)
    key1 = resp1.fetch("api_key")
    key2 = resp2.fetch("api_key")
    # The registration response shape is `{tenant: {...}, api_key:}`; the
    # tenant id sits one level deep, not at the top level.
    tenant1_id = resp1.dig("tenant", "id") || resp1.dig("tenant", :id)
    tenant2_id = resp2.dig("tenant", "id") || resp2.dig("tenant", :id)
    refute_nil tenant1_id, "expected tenant1 id in registration response"
    refute_nil tenant2_id, "expected tenant2 id in registration response"

    entity_id_1 = SecureRandom.uuid
    entity_id_2 = SecureRandom.uuid
    row1 = seed_audit_via_pg(tenant_id: tenant1_id, action: "vendors#create",     entity_id: entity_id_1)
    row2 = seed_audit_via_pg(tenant_id: tenant2_id, action: "tenant.rotate_key",  entity_id: entity_id_2)

    # 401 — no key
    res = get_request("/api/audit-log")
    assert_equal "401", res.code

    # 200 — happy path, tenant 1 sees its row when filtered by entity_id
    # (default page may not surface a freshly-seeded row if other audit
    # rows from registration accrue around the same moment).
    res = get_request("/api/audit-log?entity_id=#{entity_id_1}",
                      headers: { "X-API-Key" => key1 })
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    rows = body.fetch("entries")
    assert rows.any? { |r| r["id"] == row1 }, "expected tenant 1 to see own audit row"

    # Cross-tenant: tenant 1 querying tenant 2's entity_id returns no rows
    res = get_request("/api/audit-log?entity_id=#{entity_id_2}",
                      headers: { "X-API-Key" => key1 })
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    refute body.fetch("entries").any? { |r| r["id"] == row2 },
           "tenant 1 must not see tenant 2's audit rows"

    # 404 — tenant 1 trying to read tenant 2's row
    res = get_request("/api/audit-log/#{row2}", headers: { "X-API-Key" => key1 })
    assert_equal "404", res.code

    # 200 — tenant 2 reads its own row
    res = get_request("/api/audit-log/#{row2}", headers: { "X-API-Key" => key2 })
    assert_equal "200", res.code
    body = JSON.parse(res.body)
    assert_equal row2, body.dig("entry", "id")
  end
end
