# frozen_string_literal: true

require "test_helper"

# Integration-style test for the ApiKeyAuthenticator Rack middleware
# (PRD §5.1 + `.claude/rules/architecture_rules.md` — Tenant Scoping).
#
# The middleware:
# - Bypasses public allowlist paths (`/api/tenants/register`, `/api/health/*`,
#   `/api/signals/from-hub`).
# - For everything else under `/api/*`, requires `X-API-Key`, resolves it to
#   `Tenant`, sets `Current.tenant`, and emits 401/403 with the PRD §8b
#   JSON:API error envelope on failure.
#
# Tests draw scratch routes (same pattern as `BaseControllerTest`) so we can
# observe middleware behavior without waiting on feature controllers.
class ApiKeyAuthenticatorTest < ActionDispatch::IntegrationTest
  ACME_RAW_KEY    = "vpi_test_acme_key_00000000000000000000"
  GLOBEX_RAW_KEY  = "vpi_test_globex_key_00000000000000000"

  setup do
    Rails.application.routes.draw do
      # Scratch auth-gated endpoint — middleware MUST set Current.tenant here.
      get "/api/tenancy/probe", to: "probes#show"
      # Scratch allowlist endpoint — middleware MUST NOT intercept.
      post "/api/tenants/register", to: "probes#register"
      get  "/api/health", to: "probes#health"
      post "/api/signals/from-hub", to: "probes#from_hub"
    end

    # Swap test's default :null_store for a real in-memory store so cache
    # round-trips are observable. Restored in teardown.
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Current.tenant = nil
  end

  teardown do
    Rails.application.reload_routes!
    Current.tenant = nil
    Rails.cache = @previous_cache if @previous_cache
  end

  # ------------------------------------------------------------------
  # Scratch controller — captures whether Current.tenant was set when
  # the downstream app ran. Used to prove the middleware's behavior.
  # ------------------------------------------------------------------
  class ::ProbesController < ::ActionController::API
    def show
      render json: { tenant_id: Current.tenant&.id, slug: Current.tenant&.slug }
    end

    def register
      render json: { tenant_set: !Current.tenant.nil? }, status: :created
    end

    def health
      render json: { tenant_set: !Current.tenant.nil?, status: "ok" }
    end

    def from_hub
      render json: { tenant_set: !Current.tenant.nil? }, status: :accepted
    end
  end

  # ------------------------------------------------------------------
  # Happy path
  # ------------------------------------------------------------------
  test "valid key for active tenant sets Current.tenant and downstream sees it" do
    tenant = tenants(:acme_gmbh_de)

    get "/api/tenancy/probe", headers: { "X-API-Key" => ACME_RAW_KEY }

    assert_equal 200, response.status
    body = JSON.parse(response.body)
    assert_equal tenant.id, body["tenant_id"]
    assert_equal tenant.slug, body["slug"]
  end

  # ------------------------------------------------------------------
  # Failure modes — all emit PRD §8b envelope, not bare 401 body
  # ------------------------------------------------------------------
  test "missing X-API-Key returns 401 with UNAUTHORIZED envelope" do
    get "/api/tenancy/probe"

    assert_equal 401, response.status
    body = JSON.parse(response.body)
    assert_equal "UNAUTHORIZED", body.dig("error", "code")
    assert body.dig("error", "message").present?
    assert_match %r{application/json}, response.headers["Content-Type"]
  end

  test "blank X-API-Key returns 401 UNAUTHORIZED" do
    get "/api/tenancy/probe", headers: { "X-API-Key" => "" }
    assert_equal 401, response.status
    assert_equal "UNAUTHORIZED", JSON.parse(response.body).dig("error", "code")
  end

  test "unknown prefix returns 401 without revealing tenant existence" do
    get "/api/tenancy/probe", headers: { "X-API-Key" => "vpi_unknown_xyzabc" }
    assert_equal 401, response.status
    assert_equal "UNAUTHORIZED", JSON.parse(response.body).dig("error", "code")
  end

  test "valid prefix with tampered raw key returns 401" do
    # Correct prefix vpi_test_acm but wrong suffix — hash won't match.
    tampered = "vpi_test_acmTAMPERED0000000000000000000000"
    get "/api/tenancy/probe", headers: { "X-API-Key" => tampered }
    assert_equal 401, response.status
    assert_equal "UNAUTHORIZED", JSON.parse(response.body).dig("error", "code")
  end

  test "inactive tenant returns 403 FORBIDDEN (key valid but account disabled)" do
    tenant = tenants(:acme_gmbh_de)
    tenant.update!(is_active: false)

    get "/api/tenancy/probe", headers: { "X-API-Key" => ACME_RAW_KEY }

    assert_equal 403, response.status
    body = JSON.parse(response.body)
    assert_equal "FORBIDDEN", body.dig("error", "code")
  ensure
    tenants(:acme_gmbh_de).update!(is_active: true) if tenants(:acme_gmbh_de)
  end

  # ------------------------------------------------------------------
  # Public allowlist — middleware bypasses; downstream sees no Current.tenant
  # ------------------------------------------------------------------
  test "POST /api/tenants/register bypasses auth (allowlist) even with no key" do
    post "/api/tenants/register"
    assert_equal 201, response.status
    body = JSON.parse(response.body)
    refute body["tenant_set"], "Current.tenant must NOT be set on an allowlisted request"
  end

  test "GET /api/health bypasses auth (allowlist)" do
    get "/api/health"
    assert_equal 200, response.status
    body = JSON.parse(response.body)
    refute body["tenant_set"]
  end

  test "POST /api/signals/from-hub bypasses auth (allowlist)" do
    post "/api/signals/from-hub"
    assert_equal 202, response.status
    body = JSON.parse(response.body)
    refute body["tenant_set"]
  end

  # ------------------------------------------------------------------
  # Cache behavior — second request with same key must read from cache
  # ------------------------------------------------------------------
  test "second request with same valid key does not re-query Tenant table" do
    # Prime the cache.
    get "/api/tenancy/probe", headers: { "X-API-Key" => ACME_RAW_KEY }
    assert_equal 200, response.status

    # Observe: during the second request, Cache::TenantCache.get should return
    # a cached tenant_id and Tenant.where(...).first should NOT be invoked.
    query_count = 0
    counter = ->(_name, _started, _finished, _unique_id, payload) do
      query_count += 1 if payload[:sql]&.match?(/FROM "tenants"/i)
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      get "/api/tenancy/probe", headers: { "X-API-Key" => ACME_RAW_KEY }
    end

    assert_equal 200, response.status
    assert_equal 0, query_count,
      "Cached prefix lookup must short-circuit the Tenant DB query on second call (observed #{query_count} SELECT(s))"
  end

  # ------------------------------------------------------------------
  # Cross-tenant smoke — globex's key must yield globex, never acme
  # ------------------------------------------------------------------
  test "globex key resolves to globex, never acme (tenant isolation)" do
    globex = tenants(:globex_inc_us)

    get "/api/tenancy/probe", headers: { "X-API-Key" => GLOBEX_RAW_KEY }

    assert_equal 200, response.status
    body = JSON.parse(response.body)
    assert_equal globex.id, body["tenant_id"]
    refute_equal tenants(:acme_gmbh_de).id, body["tenant_id"]
  end
end
