# frozen_string_literal: true

require "test_helper"

module Cache
  class ScoringConfigCacheTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
    end

    teardown do
      Rails.cache = @previous_cache
    end

    test "fetch_for evaluates the block on miss and caches the result per tenant" do
      calls = 0
      result_a = Cache::ScoringConfigCache.fetch_for("tenant-a") do
        calls += 1
        { weights: { quality: 0.4 }, tenant: "a" }
      end

      assert_equal({ weights: { quality: 0.4 }, tenant: "a" }, result_a)
      assert_equal 1, calls

      # Second call for the same tenant must hit the cache.
      Cache::ScoringConfigCache.fetch_for("tenant-a") do
        calls += 1
        { weights: { quality: 999 }, tenant: "should-not-run" }
      end
      assert_equal 1, calls, "second fetch_for for tenant-a must reuse the cached value"
    end

    test "fetch_for isolates results per tenant_id" do
      Cache::ScoringConfigCache.fetch_for("tenant-a") { { tenant: "a" } }
      result_b = Cache::ScoringConfigCache.fetch_for("tenant-b") { { tenant: "b" } }

      assert_equal({ tenant: "b" }, result_b)
      assert_equal({ tenant: "a" }, Cache::ScoringConfigCache.fetch_for("tenant-a") { { tenant: "x" } })
    end

    test "invalidate clears the cached entry for a tenant" do
      Cache::ScoringConfigCache.fetch_for("tenant-a") { { version: 1 } }
      Cache::ScoringConfigCache.invalidate("tenant-a")

      calls = 0
      result = Cache::ScoringConfigCache.fetch_for("tenant-a") do
        calls += 1
        { version: 2 }
      end

      assert_equal({ version: 2 }, result)
      assert_equal 1, calls, "invalidate must force the next fetch_for to re-evaluate the block"
    end

    test "entries expire after the configured 5-minute ttl" do
      Cache::ScoringConfigCache.fetch_for("tenant-ttl") { { v: 1 } }

      travel (Cache::ScoringConfigCache::TTL_SECONDS + 1).seconds do
        calls = 0
        Cache::ScoringConfigCache.fetch_for("tenant-ttl") do
          calls += 1
          { v: 2 }
        end
        assert_equal 1, calls
      end
    end
  end
end
