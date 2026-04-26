require "test_helper"
require "net/http"
require "uri"
require "json"
require_relative "e2e_test_helper"

# E2E — Rack::Attack per-endpoint throttle (PRD §8b + §10b). Hits a RUNNING
# Puma via real HTTP so the assertion exercises the full Rack stack
# including the production Rack::Attack initializer (no in-test isolation,
# no MemoryStore swap — real Redis-backed counter on the server).
#
# Strategy: use the `scoring_rules/write/tenant` tier (10/min/tenant) which
# discriminates on X-API-Key. Every test registers a fresh disposable
# tenant so the throttle counter is isolated from sibling E2E tests. We
# avoid the `tenants/register/ip` tier (5/min/IP) because all E2E tests
# share 127.0.0.1 and tripping it would poison the rest of the suite.
class RateLimitFlowE2ETest < ActiveSupport::TestCase
  include E2ETestHelper

  def setup
    @port = ENV.fetch("E2E_PORT", "3001").to_i
    @host = "127.0.0.1"
  end

  test "scoring_rules write tier (10/min/tenant) emits 429 RATE_LIMITED with JSON envelope on the 11th request" do
    # 1. Register a disposable tenant — gets a unique X-API-Key, so the
    #    scoring_rules/write counter is per-this-key, not shared.
    api_key = register_tenant_returning_key(slug_suffix: "ratelimit-tier-#{SecureRandom.hex(3)}")
    refute_nil api_key, "registration must return a raw api_key"

    statuses = []
    # 10 writes are inside the cap — they may 400 (bad body) but MUST NOT 429.
    10.times do |i|
      response = post_scoring_rule(api_key: api_key, name: "rl-#{i}-#{SecureRandom.hex(2)}")
      statuses << response.code.to_i
      refute_equal 429, statuses.last,
        "request ##{i + 1} hit 429 prematurely (cap is 10/min/tenant); statuses=#{statuses.inspect}"
    end

    # 11th request must be throttled.
    response = post_scoring_rule(api_key: api_key, name: "rl-trip-#{SecureRandom.hex(2)}")
    assert_equal 429, response.code.to_i,
      "expected 429 on 11th request; statuses=#{statuses.inspect}, last=#{response.code}: #{response.body}"

    # Envelope check (PRD §8b).
    assert_match %r{application/json}, response["Content-Type"]
    body = JSON.parse(response.body)
    assert_equal "RATE_LIMITED", body.dig("error", "code")
    assert body.dig("error", "message").is_a?(String)
  end

  test "/api/health/ready is safelisted (BetterStack probes never throttled)" do
    20.times do
      response = Net::HTTP.get_response(URI("http://#{@host}:#{@port}/api/health/ready"))
      refute_equal 429, response.code.to_i,
        "/api/health/ready must NEVER be throttled — got #{response.code}: #{response.body}"
    end
  end

  private

  def register_tenant_returning_key(slug_suffix:)
    body = {
      slug: slug_suffix,
      legal_name: "RL Probe Co",
      full_legal_name: "Rate Limit Probe Co Ltd",
      display_name: "RLProbe",
      address: { line1: "1 RL Way", city: "Berlin", country_code: "DE" },
      registration: { tax_id: "DE-RL-#{SecureRandom.hex(4)}" },
      contact: { email: "rl@probe.example" },
      brand_primary_hex: "#000000",
      brand_accent_hex: "#FFFFFF",
      locale: "en-US",
      timezone: "UTC"
    }
    uri = URI("http://#{@host}:#{@port}/api/tenants/register")
    response = Net::HTTP.start(uri.host, uri.port) do |http|
      req = Net::HTTP::Post.new(uri.request_uri, "Content-Type" => "application/json")
      req.body = body.to_json
      http.request(req)
    end
    return nil unless response.code.to_i == 201

    JSON.parse(response.body)["api_key"]
  end

  def post_scoring_rule(api_key:, name:)
    body = {
      name: name,
      category_weights: { financial: 0.35, operational: 0.15, contractual: 0.30,
                          integration: 0.15, transactional: 0.05 },
      band_thresholds: { low_max: 25, medium_max: 50, high_max: 75 },
      window_days: 90,
      time_decay_half_life_days: 45
    }
    uri = URI("http://#{@host}:#{@port}/api/scoring_rules")
    Net::HTTP.start(uri.host, uri.port) do |http|
      req = Net::HTTP::Post.new(uri.request_uri,
                                "Content-Type" => "application/json",
                                "X-API-Key" => api_key)
      req.body = body.to_json
      http.request(req)
    end
  end
end
