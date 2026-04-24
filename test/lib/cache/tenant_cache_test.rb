# frozen_string_literal: true

require "test_helper"

module Cache
  class TenantCacheTest < ActiveSupport::TestCase
    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
    end

    teardown do
      Rails.cache = @previous_cache
    end

    test "set stores tenant_id keyed by api_key_prefix and get returns it" do
      Cache::TenantCache.set("abcd12345678", "tenant-uuid-1", ttl: 60)

      assert_equal "tenant-uuid-1", Cache::TenantCache.get("abcd12345678")
    end

    test "get returns nil for an unknown api_key_prefix" do
      assert_nil Cache::TenantCache.get("unknownprefix")
    end

    test "keys are scoped under the tenant_by_prefix namespace" do
      # Cross-namespace isolation: writing under a DIFFERENT namespace with
      # the same key must not leak into TenantCache.
      Cache::RequestCache.write(namespace: :other_namespace, key: "abcd12345678", value: "should-not-leak", ttl: 60)

      assert_nil Cache::TenantCache.get("abcd12345678"),
                 "TenantCache must only read from the tenant_by_prefix namespace"
    end

    test "stored tenant_id expires after ttl" do
      Cache::TenantCache.set("prefix-ttl", "tenant-uuid-ttl", ttl: 1)

      travel 2.seconds do
        assert_nil Cache::TenantCache.get("prefix-ttl"),
                   "expired tenant lookup must return nil so the middleware re-queries the DB"
      end
    end

    test "delete removes a cached lookup" do
      Cache::TenantCache.set("prefix-del", "tenant-uuid-del", ttl: 60)
      Cache::TenantCache.delete("prefix-del")

      assert_nil Cache::TenantCache.get("prefix-del")
    end
  end
end
