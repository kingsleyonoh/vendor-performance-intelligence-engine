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

  test "PRD §15 #11: future-date signal with no partition lands in vendor_signals_default" do
    # A date far enough in the future that no partition has been created
    # yet (PartitionManagerJob only pre-creates next month). The DEFAULT
    # partition catches these so ingestion never fails on unknown dates.
    far_future = 400.days.from_now.utc

    sig = VendorSignal.create!(signal_attrs(recorded_at: far_future))

    partition = ActiveRecord::Base.connection.select_value(
      "SELECT tableoid::regclass::text FROM vendor_signals WHERE id = '#{sig.id}'"
    )
    assert_equal "vendor_signals_default", partition,
      "far-future rows must land in the catchall partition (PRD §15 #11)"
  end

  test "PRD §15 #11: PartitionManagerJob ensures next-month partition exists without downtime" do
    # Identify the CURRENT next-month partition (created at migration).
    now = Time.now.utc
    current_next_month_name = "vendor_signals_#{now.next_month.strftime('%Y_%m')}"

    # Make a "simulated tomorrow" that crosses into the month after next —
    # the month the job is expected to create.
    simulated_now = now.next_month
    expected_new_partition = "vendor_signals_#{simulated_now.next_month.strftime('%Y_%m')}"

    # Drop the expected-new partition first to exercise the "create if
    # missing" branch. If it was somehow already present, the DROP is a
    # no-op and the test still asserts the CREATE path via the presence
    # check below.
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{expected_new_partition} CASCADE")

    refute partition_exists?(expected_new_partition),
      "test setup: #{expected_new_partition} must not exist before the job runs"

    PartitionManagerJob.perform_now(now_iso: simulated_now.iso8601)

    assert partition_exists?(expected_new_partition),
      "PartitionManagerJob must create #{expected_new_partition} when simulated_now=#{simulated_now}"

    # And it must not have regressed the original next-month partition.
    assert partition_exists?(current_next_month_name),
      "Existing next-month partition #{current_next_month_name} must remain"
  end

  private

  def partition_exists?(name)
    ActiveRecord::Base.connection.select_value(
      "SELECT 1 FROM pg_tables WHERE tablename = '#{name}'"
    ).present?
  end
end
