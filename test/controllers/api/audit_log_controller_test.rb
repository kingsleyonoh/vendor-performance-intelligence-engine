# frozen_string_literal: true

require "test_helper"

# Api::AuditLogController — PRD §5, §8, §8b, §13.3.
#
# Endpoints (all tenant-scoped via Current.tenant from X-API-Key middleware):
#
#   GET /api/audit-log              — list with filters (entity_type / entity_id /
#                                     actor_type / action / from / to) + pagination
#   GET /api/audit-log/:id          — single audit row
#
# Tenant isolation: every read goes through `where(tenant_id: Current.tenant.id)`
# so a sibling tenant's row 404s (never 403/200).
#
# "Admin-only" gate: per PRD §8 + Batch 007 design decision, the API-key
# holder IS the admin (no per-user role). A request with no/invalid
# X-API-Key returns 401. There is no in-tenant role check.
class Api::AuditLogControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant       = tenants(:acme_gmbh_de)
    @other_tenant = tenants(:globex_inc_us)
    @api_key       = "vpi_test_acme_key_00000000000000000000"
    @other_api_key = "vpi_test_globex_key_00000000000000000"
    # AuditLogEntry rows accumulate across test runs (the model is
    # insert-only at the app layer, but DELETE via raw SQL works). Wipe
    # any pre-existing rows for both tenants so per-test assertions on
    # row counts are stable.
    AuditLogEntry.where(tenant_id: [@tenant.id, @other_tenant.id]).delete_all
  end

  # ---------------- INDEX ----------------

  test "GET /api/audit-log returns rows scoped to tenant" do
    seed_audit!(tenant: @tenant,       entity: "Vendor",   action: "vendors#create")
    seed_audit!(tenant: @tenant,       entity: "Vendor",   action: "vendors#update")
    seed_audit!(tenant: @other_tenant, entity: "Vendor",   action: "vendors#create")

    # Sanity check rows actually persist before the HTTP call. Only check
    # the per-tenant slice — global count is parallel-test-fragile when
    # other tests in the same DB partition write audit rows.
    assert_equal 2, AuditLogEntry.where(tenant_id: @tenant.id).count
    assert_equal 1, AuditLogEntry.where(tenant_id: @other_tenant.id).count

    get "/api/audit-log", headers: auth_header(@api_key)
    assert_response :success
    body = JSON.parse(response.body)
    rows = body.fetch("entries")
    assert_equal 2, rows.size
    body["pagination"].tap do |p|
      assert_equal 2, p["total_count"]
      assert_equal 1, p["page"]
    end
  end

  test "GET /api/audit-log filters by entity_type" do
    seed_audit!(tenant: @tenant, entity: "Vendor",      action: "vendors#create")
    seed_audit!(tenant: @tenant, entity: "ScoringRule", action: "scoring_rules#activate")

    get "/api/audit-log", params: { entity_type: "ScoringRule" }, headers: auth_header(@api_key)
    assert_response :success
    rows = JSON.parse(response.body).fetch("entries")
    assert_equal 1, rows.size
    assert_equal "ScoringRule", rows.first["entity_type"]
  end

  test "GET /api/audit-log filters by action" do
    seed_audit!(tenant: @tenant, entity: "Vendor", action: "vendors#create")
    seed_audit!(tenant: @tenant, entity: "Vendor", action: "vendors#update")

    get "/api/audit-log", params: { audit_action: "vendors#update" }, headers: auth_header(@api_key)
    assert_response :success
    rows = JSON.parse(response.body).fetch("entries")
    assert_equal 1, rows.size
    assert_equal "vendors#update", rows.first["action"]
  end

  test "GET /api/audit-log filters by entity_id" do
    target_id = SecureRandom.uuid
    seed_audit!(tenant: @tenant, entity: "Vendor", action: "vendors#update", entity_id: target_id)
    seed_audit!(tenant: @tenant, entity: "Vendor", action: "vendors#create")

    get "/api/audit-log", params: { entity_id: target_id }, headers: auth_header(@api_key)
    assert_response :success
    rows = JSON.parse(response.body).fetch("entries")
    assert_equal 1, rows.size
    assert_equal target_id, rows.first["entity_id"]
  end

  test "GET /api/audit-log paginates with default per_page" do
    30.times { seed_audit!(tenant: @tenant, entity: "Vendor", action: "vendors#update") }

    get "/api/audit-log", headers: auth_header(@api_key)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 25, body["entries"].size  # default per_page
    assert_equal 30, body["pagination"]["total_count"]
    assert_equal 2,  body["pagination"]["total_pages"]
  end

  test "GET /api/audit-log returns rows ordered by occurred_at desc" do
    older = seed_audit!(tenant: @tenant, entity: "Vendor", action: "vendors#a", occurred_at: 2.days.ago)
    newer = seed_audit!(tenant: @tenant, entity: "Vendor", action: "vendors#b", occurred_at: 1.hour.ago)

    get "/api/audit-log", headers: auth_header(@api_key)
    assert_response :success
    rows = JSON.parse(response.body).fetch("entries")
    assert_equal newer.id, rows.first["id"]
    assert_equal older.id, rows.last["id"]
  end

  test "GET /api/audit-log without API key → 401" do
    get "/api/audit-log"
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "UNAUTHORIZED", body["error"]["code"]
  end

  # ---------------- SHOW ----------------

  test "GET /api/audit-log/:id returns the row" do
    row = seed_audit!(tenant: @tenant, entity: "Vendor", action: "vendors#update")

    get "/api/audit-log/#{row.id}", headers: auth_header(@api_key)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal row.id, body["entry"]["id"]
    assert_equal "vendors#update", body["entry"]["action"]
  end

  test "GET /api/audit-log/:id cross-tenant returns 404" do
    other_row = seed_audit!(tenant: @other_tenant, entity: "Vendor", action: "vendors#create")

    # Acme tries to read Globex's audit row — must 404, never 403
    get "/api/audit-log/#{other_row.id}", headers: auth_header(@api_key)
    assert_response :not_found
    body = JSON.parse(response.body)
    assert_equal "NOT_FOUND", body["error"]["code"]
  end

  test "GET /api/audit-log/:id with no key → 401" do
    row = seed_audit!(tenant: @tenant, entity: "Vendor", action: "vendors#update")
    get "/api/audit-log/#{row.id}"
    assert_response :unauthorized
  end

  test "GET /api/audit-log/:id unknown id → 404" do
    get "/api/audit-log/#{SecureRandom.uuid}", headers: auth_header(@api_key)
    assert_response :not_found
  end

  # ===================== Helpers =====================

  private

  def auth_header(key)
    { "X-API-Key" => key }
  end

  def seed_audit!(tenant:, entity:, action:, entity_id: SecureRandom.uuid, occurred_at: Time.current)
    row = AuditLogEntry.append!(
      tenant_id: tenant.id,
      actor_type: "Tenant",
      actor_id:   tenant.id,
      action:     action,
      entity_type: entity,
      entity_id:   entity_id,
      occurred_at: occurred_at
    )
    # Sanity: append! should return a persisted row
    raise "append! did not persist (id=nil)" unless row.persisted?
    row
  end
end
