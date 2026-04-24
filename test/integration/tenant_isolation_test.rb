# frozen_string_literal: true

require "test_helper"

# Cross-controller tenant isolation — PRD §15 criterion #9.
#
# "A curl with tenant A's API key MUST return 404 for tenant B's resources
#  in every controller."
#
# Catches regressions where a controller forgets to scope its `find` call
# through `tenant_scope` (the `tenant_id = Current.tenant.id` filter set by
# `lib/auth/api_key_authenticator.rb`).
#
# One test per /api/* endpoint that takes an :id. Shared tenants(:acme) +
# tenants(:globex) fixtures. Each test confirms the cross-tenant response
# is NOT 200 and NOT 403 — it must be 404 so the endpoint never reveals
# existence.
class TenantIsolationTest < ActionDispatch::IntegrationTest
  ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
  GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @acme = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)

    @globex_vendor = vendors(:globex_zeta)
    @globex_alias = vendor_aliases(:globex_zeta_primary)

    # A globex scoring rule exists via fixtures.
    @globex_rule = scoring_rules(:globex_default)
  end

  teardown do
    Current.tenant = nil
    Rails.cache = @previous_cache if @previous_cache
  end

  def acme_headers
    { "X-API-Key" => ACME_RAW_KEY, "Content-Type" => "application/json" }
  end

  # Guard: responses other than 404 signal a tenant-isolation bug. The
  # invariant bans 200 (data leak), 403 (existence leak), and 500 (broken
  # controller). Allow only 404.
  def assert_tenant_isolation_404(path, method: :get, body: nil)
    case method
    when :get    then get path, headers: acme_headers
    when :post   then post path, headers: acme_headers, params: body&.to_json
    when :patch  then patch path, headers: acme_headers, params: body&.to_json
    when :put    then put path, headers: acme_headers, params: body&.to_json
    when :delete then delete path, headers: acme_headers
    end

    assert_equal 404, response.status,
      "Tenant isolation (PRD §15 #9) breached on #{method.upcase} #{path}: " \
      "expected 404 for cross-tenant resource; got #{response.status}. " \
      "Body=#{response.body[0..200]}"
  end

  # -----------------------------------------------------------------
  # Vendors
  # -----------------------------------------------------------------
  test "PRD §15 #9: Acme cannot GET Globex vendor detail" do
    assert_tenant_isolation_404("/api/vendors/#{@globex_vendor.id}")
  end

  test "PRD §15 #9: Acme cannot PATCH Globex vendor" do
    assert_tenant_isolation_404(
      "/api/vendors/#{@globex_vendor.id}",
      method: :patch,
      body: { vendor: { canonical_name: "hijacked" } }
    )
  end

  test "PRD §15 #9: Acme cannot DELETE Globex vendor" do
    assert_tenant_isolation_404("/api/vendors/#{@globex_vendor.id}", method: :delete)
  end

  test "PRD §15 #9: Acme cannot MERGE into Globex vendor" do
    assert_tenant_isolation_404(
      "/api/vendors/#{@globex_vendor.id}/merge",
      method: :post,
      body: { into_vendor_id: @globex_vendor.id }
    )
  end

  # -----------------------------------------------------------------
  # Vendor scores + signals (nested under /api/vendors/:vendor_id)
  # -----------------------------------------------------------------
  test "PRD §15 #9: Acme cannot read Globex vendor score current" do
    assert_tenant_isolation_404("/api/vendors/#{@globex_vendor.id}/score/current")
  end

  test "PRD §15 #9: Acme cannot read Globex vendor score history" do
    assert_tenant_isolation_404("/api/vendors/#{@globex_vendor.id}/score/history")
  end

  test "PRD §15 #9: Acme cannot read Globex vendor signals" do
    assert_tenant_isolation_404("/api/vendors/#{@globex_vendor.id}/signals")
  end

  # -----------------------------------------------------------------
  # Vendor aliases (nested + top-level)
  # -----------------------------------------------------------------
  test "PRD §15 #9: Acme cannot GET Globex vendor's aliases list" do
    assert_tenant_isolation_404("/api/vendors/#{@globex_vendor.id}/aliases")
  end

  test "PRD §15 #9: Acme cannot GET a specific Globex vendor alias" do
    assert_tenant_isolation_404(
      "/api/vendors/#{@globex_vendor.id}/aliases/#{@globex_alias.id}"
    )
  end

  test "PRD §15 #9: Acme cannot PATCH a specific Globex vendor alias" do
    assert_tenant_isolation_404(
      "/api/vendors/#{@globex_vendor.id}/aliases/#{@globex_alias.id}",
      method: :patch,
      body: { alias: { confidence: 0.1 } }
    )
  end

  test "PRD §15 #9: Acme cannot DELETE a Globex vendor alias" do
    assert_tenant_isolation_404(
      "/api/vendors/#{@globex_vendor.id}/aliases/#{@globex_alias.id}",
      method: :delete
    )
  end

  # -----------------------------------------------------------------
  # Scoring rules
  # -----------------------------------------------------------------
  test "PRD §15 #9: Acme cannot GET a Globex scoring_rule" do
    assert_tenant_isolation_404("/api/scoring_rules/#{@globex_rule.id}")
  end

  test "PRD §15 #9: Acme cannot PATCH a Globex scoring_rule" do
    assert_tenant_isolation_404(
      "/api/scoring_rules/#{@globex_rule.id}",
      method: :patch,
      body: { scoring_rule: { name: "hijacked" } }
    )
  end

  test "PRD §15 #9: Acme cannot DELETE a Globex scoring_rule" do
    assert_tenant_isolation_404("/api/scoring_rules/#{@globex_rule.id}", method: :delete)
  end

  test "PRD §15 #9: Acme cannot ACTIVATE a Globex scoring_rule" do
    assert_tenant_isolation_404(
      "/api/scoring_rules/#{@globex_rule.id}/activate",
      method: :post
    )
  end

  test "PRD §15 #9: Acme cannot PREVIEW a Globex scoring_rule" do
    assert_tenant_isolation_404(
      "/api/scoring_rules/#{@globex_rule.id}/preview",
      method: :post,
      body: { vendor_ids: [] }
    )
  end

  # -----------------------------------------------------------------
  # Positive control — Acme asking for its OWN vendor SHOULD succeed.
  # Catches a false-positive where every endpoint just returns 404.
  # -----------------------------------------------------------------
  test "positive control: Acme CAN read its own vendor" do
    acme_vendor = vendors(:acme_alpha)
    get "/api/vendors/#{acme_vendor.id}", headers: acme_headers
    assert_equal 200, response.status
    assert_match(/Alpha Maschinenbau/, response.body)
  end
end
