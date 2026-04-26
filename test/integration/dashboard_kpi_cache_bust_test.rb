# frozen_string_literal: true

require "test_helper"

# Integration: verify that `Ingestion::SignalIngester` post-insert hook
# busts the per-tenant Dashboard KPI cache so the next dashboard render
# reflects the freshly-ingested signal. PRD §10b.
class DashboardKpiCacheBustTest < ActionDispatch::IntegrationTest
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @tenant = tenants(:acme_gmbh_de)
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "successful signal ingest invalidates Cache::DashboardKpiCache for the signal's tenant" do
    # Pre-warm the cache for the tenant.
    Cache::DashboardKpiCache.fetch_for(tenant_id: @tenant.id, kpi_name: "band_counts") do
      { "low" => 1 }
    end
    cached_before = Cache::DashboardKpiCache.fetch_for(tenant_id: @tenant.id, kpi_name: "band_counts") { "should-not-call" }
    assert_equal({ "low" => 1 }, cached_before, "cache should have been pre-warmed")

    # Pre-warm a sibling tenant's cache — must NOT be invalidated.
    other = tenants(:globex_inc_us)
    Cache::DashboardKpiCache.fetch_for(tenant_id: other.id, kpi_name: "band_counts") do
      { "low" => 99 }
    end

    # Build a payload + tenant snapshot and run the real ingester so the
    # post-insert hook fires.
    payload = {
      vendor_ref: { tax_id: "DE-cache-bust-#{SecureRandom.hex(4)}", canonical_name: "CacheBust GmbH" },
      source_system: "manual",
      source_ref: "cb-#{SecureRandom.hex(4)}",
      source_event_id: "cb-evt-#{SecureRandom.hex(8)}",
      signal_code: "invoice.late_ratio_30d",
      value_numeric: 0.10,
      recorded_at: Time.current.iso8601
    }
    Current.set(tenant: @tenant) do
      result = ::Ingestion::SignalIngester.call(payload: payload, tenant: @tenant)
      assert_equal :ingested, result[:status], "ingester must have inserted a row: #{result[:rejection_reason]}"
    end

    # The acme tenant's cache MUST be busted — block re-runs.
    fresh = Cache::DashboardKpiCache.fetch_for(tenant_id: @tenant.id, kpi_name: "band_counts") { "RECOMPUTED" }
    assert_equal "RECOMPUTED", fresh, "cache for acme must be invalidated by the post-insert hook"

    # Globex's cache MUST be untouched — only the signal's tenant is invalidated.
    other_still = Cache::DashboardKpiCache.fetch_for(tenant_id: other.id, kpi_name: "band_counts") { "SHOULD-NOT-RECOMPUTE" }
    assert_equal({ "low" => 99 }, other_still, "sibling tenant's cache must not be touched")
  end
end
