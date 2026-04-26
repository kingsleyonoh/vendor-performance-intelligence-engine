# frozen_string_literal: true

require "test_helper"

# Tenants::CaptureSnapshot — PRD §4.T. Single source of truth for the
# TenantSnapshot shape consumed by Alerts::CapturePayload (§5.5) and
# Reports::CaptureRenderContext (§5.6). Re-renders bind to a frozen copy
# stored in risk_alerts.delivery_payload / vendor_reports.tenant_snapshot
# and NEVER re-query live tenants.
class CaptureSnapshotTest < ActiveSupport::TestCase
  test "returns all §4.T keys with matching values for acme" do
    tenant = tenants(:acme_gmbh_de)
    snap = Tenants::CaptureSnapshot.call(tenant.id)

    assert_equal tenant.id, snap[:id]
    assert_equal tenant.slug, snap[:slug]
    assert_equal tenant.legal_name, snap[:legal_name]
    assert_equal tenant.full_legal_name, snap[:full_legal_name]
    assert_equal tenant.display_name, snap[:display_name]
    assert_equal tenant.address, snap[:address]
    assert_equal tenant.registration, snap[:registration]
    assert_equal tenant.contact, snap[:contact]
    # wordmark_url can be nil per schema (TEXT nullable); assert raw equality
    # which includes nil-matches-nil without assert_nil triggering.
    if tenant.wordmark_url.nil?
      assert_nil snap[:wordmark_url]
    else
      assert_equal tenant.wordmark_url, snap[:wordmark_url]
    end
    assert_equal tenant.brand_primary_hex, snap[:brand_primary_hex]
    assert_equal tenant.brand_accent_hex, snap[:brand_accent_hex]
    assert_equal tenant.locale, snap[:locale]
    assert_equal tenant.timezone, snap[:timezone]
  end

  test "snapshot_at is ISO 8601 UTC" do
    snap = Tenants::CaptureSnapshot.call(tenants(:acme_gmbh_de).id)
    assert snap[:snapshot_at].is_a?(String), "snapshot_at must be String (serializable)"
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/, snap[:snapshot_at])
  end

  test "result is frozen so callers cannot mutate a captured snapshot" do
    snap = Tenants::CaptureSnapshot.call(tenants(:acme_gmbh_de).id)
    assert snap.frozen?
    assert_raises(FrozenError) { snap[:legal_name] = "tampered" }
  end

  test "unknown tenant_id raises ActiveRecord::RecordNotFound" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Tenants::CaptureSnapshot.call("00000000-0000-0000-0000-000000000000")
    end
  end

  test "does NOT leak columns outside §4.T (e.g. api_key_hash)" do
    snap = Tenants::CaptureSnapshot.call(tenants(:acme_gmbh_de).id)
    assert_not snap.key?(:api_key_hash)
    assert_not snap.key?(:api_key_prefix)
    assert_not snap.key?(:settings)
    assert_not snap.key?(:is_active)
    assert_not snap.key?(:created_at)
    assert_not snap.key?(:updated_at)
    assert_not snap.key?(:name) # operational name, not §4.T
  end

  test "works across both tenants with distinct values (cross-tenant isolation)" do
    acme_snap = Tenants::CaptureSnapshot.call(tenants(:acme_gmbh_de).id)
    globex_snap = Tenants::CaptureSnapshot.call(tenants(:globex_inc_us).id)
    assert_not_equal acme_snap[:legal_name], globex_snap[:legal_name]
    assert_not_equal acme_snap[:locale], globex_snap[:locale]
    assert_not_equal acme_snap[:timezone], globex_snap[:timezone]
    assert_not_equal acme_snap[:address], globex_snap[:address]
  end
end
