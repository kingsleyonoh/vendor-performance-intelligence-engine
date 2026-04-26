# frozen_string_literal: true

require "test_helper"

# Cache::DashboardKpiCache — PRD §10b. Caches dashboard KPI aggregates
# per-tenant for 5 minutes; invalidated on `vendor_signals` insert via
# the SignalIngester post-insert hook (Phase 3 wiring).
module Cache
  class DashboardKpiCacheTest < ActiveSupport::TestCase
    TENANT_A = "tenant-aaa-uuid"
    TENANT_B = "tenant-bbb-uuid"

    setup do
      @previous_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
    end

    teardown do
      Rails.cache = @previous_cache
    end

    test "fetch_for invokes the block on miss and caches the result" do
      call_count = 0
      result = Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "band_counts") do
        call_count += 1
        { "low" => 3, "medium" => 1, "high" => 0, "critical" => 0 }
      end

      assert_equal 1, call_count
      assert_equal 3, result["low"]

      # Second call hits the cache — block must NOT execute again.
      again = Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "band_counts") { call_count += 1 }
      assert_equal 1, call_count, "block must only run once across cache hits"
      assert_equal 3, again["low"]
    end

    test "two tenants get isolated cache entries (no cross-tenant leak)" do
      Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "band_counts") do
        { "low" => 99 }
      end

      result_b = Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_B, kpi_name: "band_counts") do
        { "low" => 1 }
      end

      assert_equal 1, result_b["low"], "tenant B must compute its own value, not see tenant A's"
    end

    test "different kpi_names within one tenant get separate cache slots" do
      Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "band_counts") { "BANDS" }
      other = Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "status_counts") { "STATUSES" }

      assert_equal "STATUSES", other
    end

    test "invalidate(tenant_id) drops every kpi entry for that tenant" do
      Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "band_counts") { "OLD-BANDS" }
      Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "status_counts") { "OLD-STATUSES" }
      Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_B, kpi_name: "band_counts") { "B-BANDS" }

      Cache::DashboardKpiCache.invalidate(tenant_id: TENANT_A)

      # A's caches are gone — block reruns.
      a_again = Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "band_counts") { "FRESH-BANDS" }
      assert_equal "FRESH-BANDS", a_again

      # B's cache is still intact.
      b_unchanged = Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_B, kpi_name: "band_counts") { "should-not-recompute" }
      assert_equal "B-BANDS", b_unchanged
    end

    test "TTL is 300 seconds (5 minutes per PRD §10b)" do
      assert_equal 300, Cache::DashboardKpiCache::TTL_SECONDS
    end

    test "keys are namespaced under dashboard:kpi (no leak from other namespaces)" do
      Cache::RequestCache.write(
        namespace: :other_namespace,
        key: "#{TENANT_A}:band_counts",
        value: "leaked",
        ttl: 60
      )

      result = Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "band_counts") { "fresh" }
      assert_equal "fresh", result, "DashboardKpiCache must not read from a different namespace"
    end

    test "cached value expires after TTL" do
      Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "band_counts") { "first" }

      travel (Cache::DashboardKpiCache::TTL_SECONDS + 1).seconds do
        # Block executes again because the entry expired.
        again = Cache::DashboardKpiCache.fetch_for(tenant_id: TENANT_A, kpi_name: "band_counts") { "after-expiry" }
        assert_equal "after-expiry", again
      end
    end
  end
end
