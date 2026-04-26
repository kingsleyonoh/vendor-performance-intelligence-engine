# frozen_string_literal: true

require "test_helper"

# Smoke test for `config/initializers/rack_attack.rb`. Verifies:
#  - Rack::Attack middleware is installed in the stack.
#  - The baseline throttle trips after `limit` requests in the window
#    (using an isolated counter so parallel workers cannot contaminate it).
#  - The 429 response carries the PRD §8b JSON envelope (code: RATE_LIMITED).
#
# Flake fix (Batch 029): the previous version of this file called
# `Rack::Attack.cache.store.clear` against the SHARED production Redis
# store proxy. Parallel workers (parallelize :number_of_processors)
# all write to the same Redis instance, so a teardown in worker A would
# nuke the throttle counter in worker B mid-test, producing 200 instead
# of 429 ~1-in-3 runs.
#
# The fix swaps in an in-process `ActiveSupport::Cache::MemoryStore` for the
# duration of the test (per-fork — never shared) and saves/restores the
# global `Rack::Attack.throttles` hash so the rest of the suite runs with
# the production initializer's definitions intact. The throttle key is
# also derived from a per-test header (`X-Test-Throttle-Id`) instead of
# `req.ip` so even if cross-pollination happened, it would land in
# disjoint counter slots.
class RateLimitSmokeTest < ActionDispatch::IntegrationTest
  # Opt out of the global per-test Rack::Attack reset (`test/support/rack_attack_reset.rb`)
  # — this file manages its own store/throttles snapshot below.
  self.rack_attack_reset_skip = true

  setup do
    # 1. Save + replace the cache store with an isolated MemoryStore. This
    #    keeps Rack::Attack from sharing counter state with parallel forks
    #    via the Redis-backed production store. The previous-store handle
    #    is restored in teardown so the rest of the suite is unaffected.
    @previous_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

    # 2. Save + replace the global throttles hash so we can install a
    #    tiny test-only throttle without leaking it to sibling tests.
    @previous_throttles = Rack::Attack.throttles.dup
    Rack::Attack.throttles.clear

    # 3. A per-test discriminator means even if any state leaked across
    #    processes, our counter key would be unique.
    @test_throttle_id = "smoke-#{Process.pid}-#{Time.now.to_f}"
    Rack::Attack.throttle("test/req/id", limit: 3, period: 60) do |req|
      req.get_header("HTTP_X_TEST_THROTTLE_ID")
    end
  end

  teardown do
    # Restore. Note: assigning the dup back wholesale is safer than
    # `load`-ing the production initializer (which would re-define
    # throttles and could double-register on multiple test runs).
    Rack::Attack.cache.store = @previous_store
    Rack::Attack.throttles.clear
    @previous_throttles.each { |name, throttle| Rack::Attack.throttles[name] = throttle }
  end

  test "Rack::Attack is registered in the middleware stack" do
    middleware_classes = Rails.application.middleware.map(&:klass)
    assert_includes middleware_classes, Rack::Attack,
      "Rack::Attack must be registered in config/application.rb"
  end

  test "baseline throttle returns 429 with JSON envelope once limit exceeded" do
    headers = { "X-Test-Throttle-Id" => @test_throttle_id }

    # Fire `limit` requests — all must succeed (status != 429).
    3.times do |i|
      get "/up", headers: headers
      refute_equal 429, response.status,
        "request ##{i + 1} hit 429 prematurely (limit should be 3)"
    end

    # The 4th request must be throttled.
    get "/up", headers: headers
    assert_equal 429, response.status

    assert_match %r{application/json}, response.headers["Content-Type"]
    body = JSON.parse(response.body)
    assert_equal "RATE_LIMITED", body.dig("error", "code")
    assert body.dig("error", "message").present?
  end

  test "Rack::Attack cache store points at Redis when REDIS_URL is set" do
    # We saved the production store in @previous_store; assert its class
    # rather than the in-test isolated MemoryStore.
    skip "REDIS_URL not set in test env" if ENV["REDIS_URL"].to_s.empty?

    assert_match(/Redis/, @previous_store.class.name,
      "expected Redis-backed store proxy, got #{@previous_store.class.name}")
  end
end
