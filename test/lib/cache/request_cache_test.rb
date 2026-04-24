# frozen_string_literal: true

require "test_helper"

module Cache
  class RequestCacheTest < ActiveSupport::TestCase
    setup do
      # The test environment defaults to :null_store (cache reads always miss).
      # For the cache helpers themselves we need a real in-memory store so that
      # the contract (key isolation, TTL behavior, block invocation) is
      # observable. Swap in MemoryStore for the duration of each test, then
      # restore the original store in teardown.
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
    end

    teardown do
      Rails.cache = @previous_cache
    end

    test "fetch evaluates the block on first call and caches the value" do
      calls = 0
      value = Cache::RequestCache.fetch(namespace: :scratch, key: "k1", ttl: 60) do
        calls += 1
        "computed"
      end

      assert_equal "computed", value
      assert_equal 1, calls
    end

    test "fetch returns the cached value on subsequent calls without re-evaluating the block" do
      calls = 0
      2.times do
        Cache::RequestCache.fetch(namespace: :scratch, key: "k2", ttl: 60) do
          calls += 1
          "computed"
        end
      end

      assert_equal 1, calls, "block should be called once; second call must hit the cache"
    end

    test "fetch scopes keys by namespace so two namespaces with the same key are isolated" do
      ns_a = Cache::RequestCache.fetch(namespace: :ns_a, key: "same", ttl: 60) { "value_a" }
      ns_b = Cache::RequestCache.fetch(namespace: :ns_b, key: "same", ttl: 60) { "value_b" }

      assert_equal "value_a", ns_a
      assert_equal "value_b", ns_b

      # Re-fetch each — should still return the per-namespace value
      assert_equal "value_a", Cache::RequestCache.fetch(namespace: :ns_a, key: "same", ttl: 60) { "other" }
      assert_equal "value_b", Cache::RequestCache.fetch(namespace: :ns_b, key: "same", ttl: 60) { "other" }
    end

    test "fetch expires values after the configured ttl" do
      Cache::RequestCache.fetch(namespace: :scratch, key: "expires", ttl: 1) { "first" }

      # Advance wall clock beyond ttl (MemoryStore respects Time.now)
      travel 2.seconds do
        calls = 0
        value = Cache::RequestCache.fetch(namespace: :scratch, key: "expires", ttl: 1) do
          calls += 1
          "second"
        end
        assert_equal "second", value
        assert_equal 1, calls, "expired key must force block re-evaluation"
      end
    end

    test "write and read round-trip without a block" do
      Cache::RequestCache.write(namespace: :direct, key: "kw", value: 42, ttl: 60)
      assert_equal 42, Cache::RequestCache.read(namespace: :direct, key: "kw")
    end

    test "delete removes a cached value" do
      Cache::RequestCache.fetch(namespace: :scratch, key: "to_delete", ttl: 60) { "v" }
      Cache::RequestCache.delete(namespace: :scratch, key: "to_delete")
      assert_nil Cache::RequestCache.read(namespace: :scratch, key: "to_delete")
    end

    test "key construction includes the vpi prefix, namespace, and key" do
      assert_equal "vpi:scratch:abc", Cache::RequestCache.build_key(namespace: :scratch, key: "abc")
    end
  end
end
