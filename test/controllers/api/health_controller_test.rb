# frozen_string_literal: true

require "test_helper"

# Tests for /api/health/* — PRD §8, §8b. Public endpoints (no X-API-Key
# required; allowlisted in Auth::ApiKeyAuthenticator.PUBLIC_ALLOWLIST_PATHS).
#
# Surfaces:
#   GET /api/health       → liveness: always 200 when process up
#   GET /api/health/db    → 200 if Postgres reachable, 503 otherwise
#   GET /api/health/redis → 200 if Redis reachable, 503 otherwise
#   GET /api/health/ready → 200 iff DB + Redis + Sidekiq all healthy
#
# Response shape:
#   200 { status: "ok", service: "vpi", ... }
#   503 { status: "unavailable", details: { component: message } }
module Api
  class HealthControllerTest < ActionDispatch::IntegrationTest
    def teardown
      ::Api::HealthController.reset_probes_for_test!
    end

    # --------------------------------------------------------------
    # Liveness
    # --------------------------------------------------------------

    test "GET /api/health returns 200 with service identity (no auth required)" do
      get "/api/health"
      assert_equal 200, response.status, response.body
      body = JSON.parse(response.body)
      assert_equal "ok", body["status"]
      assert_equal "vpi", body["service"]
      assert body.key?("version"), "expected version key"
    end

    test "GET /api/health does not require X-API-Key" do
      # Explicitly no headers
      get "/api/health"
      assert_equal 200, response.status
    end

    # --------------------------------------------------------------
    # DB probe
    # --------------------------------------------------------------

    test "GET /api/health/db returns 200 when Postgres is reachable" do
      get "/api/health/db"
      assert_equal 200, response.status, response.body
      assert_equal "ok", JSON.parse(response.body)["status"]
    end

    test "GET /api/health/db returns 503 when DB query raises" do
      ::Api::HealthController.db_probe = -> { raise ActiveRecord::ConnectionNotEstablished, "simulated DB outage" }
      get "/api/health/db"
      assert_equal 503, response.status, response.body
      body = JSON.parse(response.body)
      assert_equal "unavailable", body["status"]
      assert body.dig("details", "db").present?
    end

    # --------------------------------------------------------------
    # Redis probe
    # --------------------------------------------------------------

    test "GET /api/health/redis returns 200 when Redis is reachable" do
      get "/api/health/redis"
      assert_equal 200, response.status, response.body
      assert_equal "ok", JSON.parse(response.body)["status"]
    end

    test "GET /api/health/redis returns 503 when Redis ping raises" do
      ::Api::HealthController.redis_probe = -> { raise Redis::CannotConnectError, "no redis" }
      get "/api/health/redis"
      assert_equal 503, response.status, response.body
      body = JSON.parse(response.body)
      assert_equal "unavailable", body["status"]
      assert body.dig("details", "redis").present?
    end

    # --------------------------------------------------------------
    # Readiness — aggregate
    # --------------------------------------------------------------

    test "GET /api/health/ready returns 200 when every component is healthy" do
      get "/api/health/ready"
      assert_equal 200, response.status, response.body
      body = JSON.parse(response.body)
      assert_equal "ok", body["status"]
      # Explicit per-component roll-up so operators can see what passed.
      assert_equal "ok", body.dig("components", "db")
      assert_equal "ok", body.dig("components", "redis")
      assert_equal "ok", body.dig("components", "sidekiq")
    end

    test "GET /api/health/ready returns 503 when a component fails" do
      ::Api::HealthController.db_probe = -> { raise ActiveRecord::ConnectionNotEstablished, "simulated DB outage" }
      get "/api/health/ready"
      assert_equal 503, response.status, response.body
      body = JSON.parse(response.body)
      assert_equal "unavailable", body["status"]
      assert_equal "error", body.dig("components", "db")
    end
  end
end
