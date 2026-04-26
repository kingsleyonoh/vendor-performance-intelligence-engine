# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"
require_relative "e2e_test_helper"

# E2E for /api/health/* — PRD §8, §10b. Hits a real Puma; verifies all four
# health endpoints return 200 when Postgres + Redis are up (the standard
# `docker compose up -d postgres redis` state).
class HealthFlowE2ETest < ActiveSupport::TestCase
  include E2ETestHelper

  BASE_URL = ENV.fetch("E2E_BASE_URL", "http://127.0.0.1:3001")

  def get_json(path, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Get.new(uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  test "GET /api/health returns 200 with service identity over real HTTP" do
    res = get_json("/api/health")
    assert_equal "200", res.code, "health: #{res.code} #{res.body}"
    body = JSON.parse(res.body)
    assert_equal "ok", body["status"]
    assert_equal "vpi", body["service"]
  end

  test "GET /api/health/db returns 200 when Postgres is reachable" do
    res = get_json("/api/health/db")
    assert_equal "200", res.code, "health/db: #{res.code} #{res.body}"
  end

  test "GET /api/health/redis returns 200 when Redis is reachable" do
    res = get_json("/api/health/redis")
    assert_equal "200", res.code, "health/redis: #{res.code} #{res.body}"
  end

  test "GET /api/health/ready returns 200 when every component is healthy" do
    res = get_json("/api/health/ready")
    assert_equal "200", res.code, "health/ready: #{res.code} #{res.body}"
    body = JSON.parse(res.body)
    assert_equal "ok", body["status"]
    assert_equal "ok", body.dig("components", "db")
    assert_equal "ok", body.dig("components", "redis")
    assert_equal "ok", body.dig("components", "sidekiq")
  end

  test "health endpoints do not require X-API-Key" do
    %w[/api/health /api/health/db /api/health/redis /api/health/ready].each do |path|
      res = get_json(path)
      assert_equal "200", res.code, "#{path} must be public: #{res.code} #{res.body}"
    end
  end
end
