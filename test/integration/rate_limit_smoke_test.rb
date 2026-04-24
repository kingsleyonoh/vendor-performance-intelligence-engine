# frozen_string_literal: true

require "test_helper"

# Smoke test for `config/initializers/rack_attack.rb`. Verifies:
#  - Rack::Attack middleware is installed in the stack.
#  - The baseline `req/ip` throttle trips after `limit` requests in the window.
#  - The 429 response carries the PRD §8b JSON envelope (code: RATE_LIMITED).
#
# Uses the real Redis store (compose `redis` service) because the project
# mandates "don't mock what you own" (CODING_STANDARDS_TESTING_LIVE.md). The
# baseline limit is 600/min — far too many to exercise directly, so we flip
# the throttle to a tiny limit for the duration of the test via Rack::Attack's
# public API, then restore.
class RateLimitSmokeTest < ActionDispatch::IntegrationTest
  setup do
    # Flush any pre-existing Rack::Attack counters so a prior test run does not
    # push us over the threshold before we start counting.
    Rack::Attack.cache.store.clear if Rack::Attack.cache.store.respond_to?(:clear)

    # Replace the production throttle with a tight one for deterministic tests.
    # Rack::Attack keeps throttles in a hash — overwriting by the same name
    # is the documented override path.
    Rack::Attack.throttles.clear
    Rack::Attack.throttle("test/req/ip", limit: 3, period: 60) { |req| req.ip }
  end

  teardown do
    Rack::Attack.cache.store.clear if Rack::Attack.cache.store.respond_to?(:clear)
    Rack::Attack.throttles.clear
    # Re-load the production initializer so the rest of the suite runs with it.
    load Rails.root.join("config/initializers/rack_attack.rb")
  end

  test "Rack::Attack is registered in the middleware stack" do
    middleware_classes = Rails.application.middleware.map(&:klass)
    assert_includes middleware_classes, Rack::Attack,
      "Rack::Attack must be registered in config/application.rb"
  end

  test "baseline throttle returns 429 with JSON envelope once limit exceeded" do
    # Fire `limit` requests — all must succeed (status != 429).
    3.times do |i|
      get "/up"
      refute_equal 429, response.status,
        "request ##{i + 1} hit 429 prematurely (limit should be 3)"
    end

    # The 4th request must be throttled.
    get "/up"
    assert_equal 429, response.status

    assert_match %r{application/json}, response.headers["Content-Type"]
    body = JSON.parse(response.body)
    assert_equal "RATE_LIMITED", body.dig("error", "code")
    assert body.dig("error", "message").present?
  end

  test "Rack::Attack cache store points at Redis in non-test-memory envs" do
    # The initializer uses the Redis URL from env. We don't assert exact URL —
    # just that the store type is a RedisCacheStore when REDIS_URL is set.
    skip "REDIS_URL not set in test env" if ENV["REDIS_URL"].to_s.empty?

    # teardown re-loads the initializer; invoke it once here against a fresh
    # Rack::Attack state to observe the real store type.
    Rack::Attack.throttles.clear
    load Rails.root.join("config/initializers/rack_attack.rb")

    # Rack::Attack wraps the configured store in a StoreProxy — so we assert
    # the proxy is a Redis proxy (not a MemoryStore proxy), which means the
    # initializer correctly resolved REDIS_URL and constructed a RedisCacheStore.
    store_class_name = Rack::Attack.cache.store.class.name
    assert_match(/Redis/, store_class_name,
      "expected Redis-backed store proxy, got #{store_class_name}")
  end
end
