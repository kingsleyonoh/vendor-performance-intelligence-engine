# frozen_string_literal: true

require "test_helper"

# Ingestion::SignalIngester — PRD §5.3. The full ingestion pipeline:
# validate → dedup → resolve vendor → range-check → insert vendor_signals
# → fire post_insert_hook (the alert/scoring dispatcher, wired by Phase 2).
#
# Returns: { status: :ingested | :deduped | :rejected,
#            signal: VendorSignal | nil,
#            rejection_reason: String | nil,
#            vendor: Vendor | nil }
#
# Tenant isolation enforced by the resolver + by scoping VendorSignal
# queries to `tenant_id`. The post-insert hook is exposed as a class-level
# configuration point (not a placeholder): Phase 2 wires the
# ScoreRecomputeJob enqueue into it.
class SignalIngesterTest < ActiveSupport::TestCase
  def setup
    @acme = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    ensure_signal_catalog_seeded
    @hook_invocations = []
    @saved_hook = Ingestion::SignalIngester.post_insert_hook
    Ingestion::SignalIngester.post_insert_hook = ->(signal) { @hook_invocations << signal }
  end

  def teardown
    Ingestion::SignalIngester.post_insert_hook = @saved_hook
  end

  def valid_payload(overrides = {})
    {
      vendor_ref: { source_system_ref: "upstream-acme-001",
                    normalized_name: "acme supplier gmbh" },
      signal_code: "invoice.late_ratio_30d",
      source_system: "invoice_recon",
      source_event_id: "evt-#{SecureRandom.hex(4)}",
      value_numeric: 0.20,
      recorded_at: (Time.now.utc - 1.day).iso8601
    }.merge(overrides)
  end

  # ---------------- Happy path ----------------

  test "happy path: valid payload → ingested, signal persisted, hook fires" do
    result = Ingestion::SignalIngester.call(payload: valid_payload, tenant: @acme)

    assert_equal :ingested, result[:status]
    assert result[:signal].is_a?(VendorSignal)
    assert result[:signal].persisted?
    assert_equal @acme.id, result[:signal].tenant_id
    assert_equal 1, @hook_invocations.length
    assert_equal result[:signal].id, @hook_invocations.first.id
  end

  test "creates a new vendor via resolver when no prior alias exists" do
    assert_difference -> { Vendor.where(tenant_id: @acme.id).count }, +1 do
      Ingestion::SignalIngester.call(payload: valid_payload, tenant: @acme)
    end
  end

  test "reuses existing vendor via alias on second call with same source_ref" do
    p1 = valid_payload(source_event_id: "evt-1")
    Ingestion::SignalIngester.call(payload: p1, tenant: @acme)

    p2 = valid_payload(source_event_id: "evt-2") # same vendor_ref, new event
    assert_no_difference -> { Vendor.where(tenant_id: @acme.id).count } do
      Ingestion::SignalIngester.call(payload: p2, tenant: @acme)
    end
  end

  # ---------------- Dedup ----------------

  test "dedup: same (source_system, source_event_id) on second call → :deduped" do
    r1 = Ingestion::SignalIngester.call(payload: valid_payload(source_event_id: "dup-1"), tenant: @acme)
    r2 = Ingestion::SignalIngester.call(payload: valid_payload(source_event_id: "dup-1"), tenant: @acme)

    assert_equal :ingested, r1[:status]
    assert_equal :deduped, r2[:status]
    assert_equal r1[:signal].id, r2[:signal].id
    # Hook fires only on the first (real) insert
    assert_equal 1, @hook_invocations.length
  end

  # ---------------- Reject matrix ----------------

  test "reject: UNKNOWN_SIGNAL_CODE" do
    result = Ingestion::SignalIngester.call(
      payload: valid_payload(signal_code: "bogus.not_a_signal"),
      tenant: @acme
    )
    assert_equal :rejected, result[:status]
    assert_equal "UNKNOWN_SIGNAL_CODE", result[:rejection_reason]
    assert_nil result[:signal]
    assert_empty @hook_invocations
  end

  test "reject: VALUE_OUT_OF_RANGE for rate > 1.0" do
    result = Ingestion::SignalIngester.call(
      payload: valid_payload(value_numeric: 2.5),
      tenant: @acme
    )
    assert_equal :rejected, result[:status]
    assert_equal "VALUE_OUT_OF_RANGE", result[:rejection_reason]
  end

  test "reject: FUTURE_TIMESTAMP" do
    result = Ingestion::SignalIngester.call(
      payload: valid_payload(recorded_at: (Time.now.utc + 3.hours).iso8601),
      tenant: @acme
    )
    assert_equal :rejected, result[:status]
    assert_equal "FUTURE_TIMESTAMP", result[:rejection_reason]
  end

  test "reject: STALE_TIMESTAMP" do
    result = Ingestion::SignalIngester.call(
      payload: valid_payload(recorded_at: (Time.now.utc - 400.days).iso8601),
      tenant: @acme
    )
    assert_equal :rejected, result[:status]
    assert_equal "STALE_TIMESTAMP", result[:rejection_reason]
  end

  test "reject: WINDOW_INVERTED" do
    result = Ingestion::SignalIngester.call(
      payload: valid_payload(
        window_start: (Time.now.utc - 1.day).iso8601,
        window_end: (Time.now.utc - 10.days).iso8601
      ),
      tenant: @acme
    )
    assert_equal :rejected, result[:status]
    assert_equal "WINDOW_INVERTED", result[:rejection_reason]
  end

  test "reject: MISSING_VENDOR_REF (empty vendor_ref hash)" do
    result = Ingestion::SignalIngester.call(
      payload: valid_payload(vendor_ref: {}),
      tenant: @acme
    )
    assert_equal :rejected, result[:status]
    assert_equal "MISSING_VENDOR_REF", result[:rejection_reason]
  end

  # ---------------- Terminated vendor ----------------

  test "reject: TERMINATED_VENDOR when resolver returns a terminated vendor" do
    # Pre-create a terminated vendor matched by the resolver's rung-3 path
    terminated = Vendor.create!(tenant: @acme, canonical_name: "Terminated Co",
                                status: "terminated")
    # Pre-create alias for source_ref so rung-1 hits terminated
    VendorAlias.create!(tenant: @acme, vendor: terminated,
                        source_system: "invoice_recon",
                        source_ref: "terminated-src-ref",
                        confidence: 1.0, is_confirmed: true)

    result = Ingestion::SignalIngester.call(
      payload: valid_payload(vendor_ref: { source_system_ref: "terminated-src-ref" }),
      tenant: @acme
    )
    assert_equal :rejected, result[:status]
    assert_equal "TERMINATED_VENDOR", result[:rejection_reason]
    assert_empty @hook_invocations
  end

  # ---------------- Tenant isolation ----------------

  test "tenant isolation: Acme-tagged signal never lands in Globex-owned vendor" do
    Ingestion::SignalIngester.call(payload: valid_payload, tenant: @acme)
    Ingestion::SignalIngester.call(payload: valid_payload, tenant: @globex)

    acme_vendors = Vendor.where(tenant_id: @acme.id).pluck(:id)
    globex_vendors = Vendor.where(tenant_id: @globex.id).pluck(:id)
    # No overlap
    assert_empty acme_vendors & globex_vendors
    # Each tenant has its own signal
    assert_equal 1, VendorSignal.where(tenant_id: @acme.id,
                                        vendor_id: acme_vendors).count
    assert_equal 1, VendorSignal.where(tenant_id: @globex.id,
                                        vendor_id: globex_vendors).count
  end

  # ---------------- post_insert_hook contract ----------------

  test "post_insert_hook is NOT invoked on dedup" do
    Ingestion::SignalIngester.call(payload: valid_payload(source_event_id: "dup-hook-1"), tenant: @acme)
    @hook_invocations.clear
    Ingestion::SignalIngester.call(payload: valid_payload(source_event_id: "dup-hook-1"), tenant: @acme)
    assert_empty @hook_invocations
  end

  test "post_insert_hook is NOT invoked on reject" do
    Ingestion::SignalIngester.call(
      payload: valid_payload(signal_code: "bogus"),
      tenant: @acme
    )
    assert_empty @hook_invocations
  end

  test "post_insert_hook can be swapped per-process (Phase 2 wires ScoreRecomputeJob)" do
    original = Ingestion::SignalIngester.post_insert_hook
    begin
      Ingestion::SignalIngester.post_insert_hook = ->(_s) { raise "testing custom hook" }
      assert_raises(RuntimeError) do
        Ingestion::SignalIngester.call(
          payload: valid_payload(source_event_id: "custom-hook"),
          tenant: @acme
        )
      end
    ensure
      Ingestion::SignalIngester.post_insert_hook = original
    end
  end

  private

  def ensure_signal_catalog_seeded
    return if SignalDefinition.exists?

    yml = YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml"))
    yml.each { |row| SignalDefinition.create!(row) }
  end
end
