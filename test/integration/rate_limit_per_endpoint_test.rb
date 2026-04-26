# frozen_string_literal: true

require "test_helper"

# Per-endpoint Rack::Attack throttle tests — PRD §8b. Verifies the
# initializer registers the canonical throttle definitions tuned to the
# §8b table (signals 600/min, scoring_rules write 10/min, register 5/min,
# rotate-key 2/min, etc.) and that read endpoints get higher caps than
# writes. Health and metrics paths MUST be allowlisted.
class RateLimitPerEndpointTest < ActiveSupport::TestCase
  test "throttle definitions cover every §8b endpoint category" do
    names = Rack::Attack.throttles.keys

    # The five canonical tiers from PRD §8b.
    assert_includes names, "tenants/register/ip",        "self-registration must remain throttled (5/min/IP)"
    assert_includes names, "rotate_key/tenant",          "rotate-key must be a tight per-tenant tier (2/min)"
    assert_includes names, "signals/write/tenant",       "POST /api/signals must be throttled (600/min/tenant)"
    assert_includes names, "vendors/read/tenant",        "vendor reads must be throttled (high cap)"
    assert_includes names, "vendors/write/tenant",       "vendor writes must be throttled (low cap)"
    assert_includes names, "scoring_rules/write/tenant", "scoring rules writes must be throttled (low cap)"
    assert_includes names, "reports/write/tenant",       "report creation must be throttled (low cap)"
  end

  test "read tiers have higher limits than write tiers (read-vs-write distinction)" do
    read_limit  = Rack::Attack.throttles["vendors/read/tenant"].limit
    write_limit = Rack::Attack.throttles["vendors/write/tenant"].limit

    # Both are integers (not procs) so we can compare directly.
    assert read_limit.is_a?(Integer), "vendors/read/tenant.limit must be an Integer"
    assert write_limit.is_a?(Integer), "vendors/write/tenant.limit must be an Integer"
    assert read_limit > write_limit,
           "read cap (#{read_limit}) must be higher than write cap (#{write_limit}) per PRD §8b"
  end

  test "admin tiers (rotate-key) have the tightest limits per PRD §8b" do
    rotate = Rack::Attack.throttles["rotate_key/tenant"].limit
    assert_equal 2, rotate, "rotate-key must be 2/min/tenant per PRD §8b"
  end

  test "register tier matches PRD §8b spec (5/min/IP, period 60)" do
    register = Rack::Attack.throttles["tenants/register/ip"]
    assert_equal 5,  register.limit
    assert_equal 60, register.period
  end

  test "signals tier matches PRD §8b spec (600/min)" do
    signals = Rack::Attack.throttles["signals/write/tenant"]
    assert_equal 600, signals.limit
    assert_equal 60,  signals.period
  end

  test "/api/health and /metrics paths bypass throttling (safelist)" do
    safelist_names = Rack::Attack.safelists.keys
    # The metrics safelist is named "metrics-scrape" by the initializer.
    # The health safelist is added by this batch's tuning work.
    assert_includes safelist_names, "metrics-scrape",
                    "/metrics scrapes must be safelisted"
    assert_includes safelist_names, "health-checks",
                    "/api/health* paths must be safelisted (BetterStack probes 60s)"
  end

  test "throttled responder emits the canonical RATE_LIMITED JSON envelope" do
    # The responder is a callable that takes a request and returns a Rack
    # 3-tuple. We invoke it with a stub request to verify the shape.
    responder = Rack::Attack.throttled_responder
    refute_nil responder, "throttled_responder must be configured"

    status, headers, body = responder.call(nil)
    assert_equal 429, status
    assert_equal "application/json; charset=utf-8", headers["Content-Type"]

    parsed = JSON.parse(body.first)
    assert_equal "RATE_LIMITED", parsed.dig("error", "code")
    assert parsed.dig("error", "message").is_a?(String)
  end
end

# Live-fire verification: this class exercises the actual throttle counter
# against the real cache store. Single test class, no parallelization
# contamination because we use a per-test discriminator and isolated
# MemoryStore (mock-policy: real Rack::Attack in-process — never mocked).
class RateLimitWriteTierLiveTest < ActionDispatch::IntegrationTest
  # Opt out of the global per-test Rack::Attack reset — this file manages its
  # own store + throttles snapshot below.
  self.rack_attack_reset_skip = true

  # Use an isolated MemoryStore in setup so parallel workers don't share
  # counter state via the production Redis-backed proxy.
  setup do
    @prev_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    @prev_throttles = Rack::Attack.throttles.dup
    Rack::Attack.throttles.clear
    @id = "live-tier-#{Process.pid}-#{Time.now.to_f}"

    # Inject a tiny tier scoped to a unique header so cross-test traffic
    # cannot increment our counter, and our counter cannot affect anyone else.
    Rack::Attack.throttle("test/tier-write", limit: 2, period: 60) do |req|
      req.get_header("HTTP_X_TEST_TIER_ID") if req.path.start_with?("/up")
    end
  end

  teardown do
    Rack::Attack.cache.store = @prev_store
    Rack::Attack.throttles.clear
    @prev_throttles.each { |name, throttle| Rack::Attack.throttles[name] = throttle }
  end

  test "throttle trips at limit + 1 and emits RATE_LIMITED envelope" do
    headers = { "X-Test-Tier-Id" => @id }

    2.times do |i|
      get "/up", headers: headers
      refute_equal 429, response.status, "request ##{i + 1} must NOT be throttled (under limit)"
    end

    get "/up", headers: headers
    assert_equal 429, response.status

    parsed = JSON.parse(response.body)
    assert_equal "RATE_LIMITED", parsed.dig("error", "code")
  end
end
