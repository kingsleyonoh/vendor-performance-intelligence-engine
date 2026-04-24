# frozen_string_literal: true

require "test_helper"

# Partition rollover — PRD §15 criterion #11. vendor_signals is partitioned
# monthly by recorded_at. A row inserted for "next month" must land in a
# different partition than the "current month" row.
class PartitionRolloverTest < ActiveSupport::TestCase
  def setup
    @acme = tenants(:acme_gmbh_de)
    @vendor = Vendor.create!(tenant: @acme, canonical_name: "Acme Rollover Ltd")
  end

  def signal_attrs(recorded_at:)
    {
      tenant_id: @acme.id,
      vendor_id: @vendor.id,
      signal_code: "invoice.late_ratio_30d",
      source_system: "invoice_recon",
      source_event_id: "rollover-#{SecureRandom.hex(6)}",
      value_numeric: 0.05,
      recorded_at: recorded_at
    }
  end

  test "current-month and next-month rows land in different partitions" do
    now = Time.now.utc
    current = Time.utc(now.year, now.month, 15) # mid-current-month
    nxt = current.next_month                     # same day next month

    s_current = VendorSignal.create!(signal_attrs(recorded_at: current))
    s_next = VendorSignal.create!(signal_attrs(recorded_at: nxt))

    # Postgres exposes the physical partition via the `tableoid` system column.
    current_part = ActiveRecord::Base.connection.select_value(
      "SELECT tableoid::regclass::text FROM vendor_signals WHERE id = '#{s_current.id}'"
    )
    next_part = ActiveRecord::Base.connection.select_value(
      "SELECT tableoid::regclass::text FROM vendor_signals WHERE id = '#{s_next.id}'"
    )

    refute_equal current_part, next_part,
                 "current-month and next-month rows must be in different partitions"
    assert_match(/vendor_signals_\d{4}_\d{2}/, current_part)
    assert_match(/vendor_signals_\d{4}_\d{2}/, next_part)
  end

  test "reads from parent return rows from every partition" do
    now = Time.now.utc
    current = Time.utc(now.year, now.month, 10)
    nxt = current.next_month

    VendorSignal.create!(signal_attrs(recorded_at: current))
    VendorSignal.create!(signal_attrs(recorded_at: nxt))

    rows = VendorSignal.where(vendor_id: @vendor.id).count
    assert_operator rows, :>=, 2
  end
end
