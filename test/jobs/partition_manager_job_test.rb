# frozen_string_literal: true

require "test_helper"

# PartitionManagerJob — PRD §4.5, §7. Daily cron job (01:00 UTC) that:
#   1. Creates the next-month partition on vendor_signals if missing.
#   2. Drops partitions older than the retention window (default 24 months).
#   3. Logs operations via Audit::Recorder.
#
# Runs tenant-agnostic at the Postgres level; no tenant resolution needed.
class PartitionManagerJobTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @cleanup_tables = []
  end

  def teardown
    @cleanup_tables.each do |tbl|
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{tbl} CASCADE")
    rescue StandardError
      # ignore
    end
  end

  # ------------------------------------------------------------
  # Creates the next-month partition if missing
  # ------------------------------------------------------------

  test "creates next-month partition when missing" do
    target_month = Time.now.utc.beginning_of_month.next_month.next_month # 2 months out to avoid the seed partition
    expected_name = "vendor_signals_#{target_month.strftime('%Y_%m')}"
    @cleanup_tables << expected_name

    # Precondition: partition for this target month does not exist.
    drop_partition_if_exists(expected_name)
    refute partition_exists?(expected_name), "precondition: partition should not exist"

    # Invoke with frozen "now" one month earlier so next_month === target_month
    now = target_month.prev_month
    PartitionManagerJob.perform_now(now_iso: now.iso8601)

    assert partition_exists?(expected_name), "expected partition #{expected_name} to be created"
  end

  # ------------------------------------------------------------
  # Idempotent — no-op when partition already exists
  # ------------------------------------------------------------

  test "is idempotent when partition already exists" do
    target_month = Time.now.utc.beginning_of_month.next_month.next_month
    now = target_month.prev_month
    expected_name = "vendor_signals_#{target_month.strftime('%Y_%m')}"
    @cleanup_tables << expected_name

    PartitionManagerJob.perform_now(now_iso: now.iso8601)
    assert partition_exists?(expected_name)

    # Run again — must not raise.
    assert_nothing_raised do
      PartitionManagerJob.perform_now(now_iso: now.iso8601)
    end
    assert partition_exists?(expected_name)
  end

  # ------------------------------------------------------------
  # Drops partitions older than retention window
  # ------------------------------------------------------------

  test "drops partitions older than retention window" do
    retention_months = 24
    # Create a synthetic "ancient" partition 3 years ago.
    ancient = (Time.now.utc - 36.months).beginning_of_month
    ancient_name = "vendor_signals_#{ancient.strftime('%Y_%m')}"
    @cleanup_tables << ancient_name

    drop_partition_if_exists(ancient_name)
    ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TABLE #{ancient_name}
        PARTITION OF vendor_signals
        FOR VALUES FROM ('#{ancient.strftime('%Y-%m-%d')}')
                   TO   ('#{ancient.next_month.strftime('%Y-%m-%d')}');
    SQL
    assert partition_exists?(ancient_name), "sanity: ancient partition should be created"

    # Run with retention = 24 months
    ENV["VENDOR_SIGNALS_RETENTION_MONTHS"] = retention_months.to_s
    PartitionManagerJob.perform_now
    ENV.delete("VENDOR_SIGNALS_RETENTION_MONTHS")

    refute partition_exists?(ancient_name),
           "ancient partition (#{ancient_name}) older than #{retention_months} months should be dropped"
  end

  # ------------------------------------------------------------
  # Default partition is never dropped
  # ------------------------------------------------------------

  test "does not drop the default partition" do
    PartitionManagerJob.perform_now
    assert partition_exists?("vendor_signals_default"),
           "default partition must never be dropped"
  end

  # ------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------

  private

  def partition_exists?(name)
    result = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT 1 FROM pg_tables WHERE tablename = '#{name}'
    SQL
    result.present?
  end

  def drop_partition_if_exists(name)
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{name} CASCADE")
  end
end
