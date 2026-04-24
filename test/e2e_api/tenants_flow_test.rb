# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"

# Shell-level E2E against a booted Puma for the Phase 1 tenant identity
# surface: register -> me -> rotate-key -> old key denied / new key works.
# `bin/dc bin/rake test:e2e` boots Puma via ServerBoot and runs this file.
#
# Endpoints exercised:
#   POST /api/tenants/register
#   GET  /api/tenants/me
#   POST /api/tenants/me/rotate-key
class TenantsFlowE2ETest < ActiveSupport::TestCase
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

  def get_json(path, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Get.new(uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  test "register -> me -> rotate-key full flow over real HTTP" do
    body = {
      slug: "e2e-test-#{Time.now.to_i}",
      legal_name: "E2E Test Ltd",
      full_legal_name: "E2E Test Private Limited",
      display_name: "E2E",
      address: { line1: "10 Test St", city: "Testville", country_code: "GB" },
      registration: { tax_id: "GB-E2E-123", company_number: "00000001" },
      contact: { email: "hello@e2e.example" }
    }

    # 1. Register
    register_res = post_json("/api/tenants/register", body)
    assert_equal "201", register_res.code,
      "register expected 201, got #{register_res.code}: #{register_res.body}"
    payload = JSON.parse(register_res.body)
    first_key = payload["api_key"]
    assert first_key.is_a?(String) && first_key.length >= 20,
      "register must return raw api_key — got #{payload.inspect}"

    # 2. /me with the returned key
    me_res = get_json("/api/tenants/me", headers: { "X-API-Key" => first_key })
    assert_equal "200", me_res.code,
      "/me expected 200 with fresh key, got #{me_res.code}: #{me_res.body}"
    me_body = JSON.parse(me_res.body)
    assert_equal body[:display_name], me_body.dig("tenant", "display_name")

    # 3. Rotate key
    rotate_res = post_json("/api/tenants/me/rotate-key", {}, headers: { "X-API-Key" => first_key })
    assert_equal "200", rotate_res.code,
      "rotate-key expected 200, got #{rotate_res.code}: #{rotate_res.body}"
    new_key = JSON.parse(rotate_res.body)["api_key"]
    assert new_key.is_a?(String) && new_key != first_key,
      "rotate-key must return a different raw key"

    # 4. Old key now 401
    old_res = get_json("/api/tenants/me", headers: { "X-API-Key" => first_key })
    assert_equal "401", old_res.code,
      "old key MUST be 401 after rotation, got #{old_res.code}"

    # 5. New key works
    new_res = get_json("/api/tenants/me", headers: { "X-API-Key" => new_key })
    assert_equal "200", new_res.code,
      "new key MUST be 200, got #{new_res.code}: #{new_res.body}"
  end

  test "GET /api/tenants/me without X-API-Key returns 401 JSON envelope" do
    res = get_json("/api/tenants/me")
    assert_equal "401", res.code
    body = JSON.parse(res.body)
    assert_equal "UNAUTHORIZED", body.dig("error", "code")
  end
end
