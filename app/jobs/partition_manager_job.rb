# frozen_string_literal: true

# PartitionManagerJob — PRD §4.5, §7. Runs daily at 01:00 UTC. Keeps
# `vendor_signals` monthly partitions healthy:
#
#   1. Ensures next month's partition exists (creates if missing). This
#      guarantees month-boundary rollover without downtime (PRD §15 #11).
#   2. Drops partitions older than VENDOR_SIGNALS_RETENTION_MONTHS (default
#      24 months). Never drops `vendor_signals_default`.
#   3. Records each DDL operation via Audit::Recorder so ops teams can
#      trace partition lifecycle.
#
# Tenant-agnostic (operates at the Postgres level). Safe to run multiple
# times per day — every DDL is wrapped with `IF [NOT] EXISTS`.
#
# Contract:
#   PartitionManagerJob.perform_later
#   PartitionManagerJob.perform_now(now_iso: "2026-05-01T00:00:00Z")
#
# The optional `now_iso` kwarg exists for deterministic tests — production
# callers omit it and the job reads `Time.now.utc`.
class PartitionManagerJob < ApplicationJob
  queue_as :default

  DEFAULT_RETENTION_MONTHS = 24
  PARTITION_NAME_REGEX = /\Avendor_signals_(\d{4})_(\d{2})\z/

  def perform(now_iso: nil)
    now = now_iso ? Time.iso8601(now_iso).utc : Time.now.utc

    ensure_next_month_partition(now)
    drop_expired_partitions(now)

    nil
  end

  private

  def ensure_next_month_partition(now)
    target = now.beginning_of_month.next_month
    name = partition_name_for(target)

    return if partition_exists?(name)

    range_start = target.strftime("%Y-%m-%d")
    range_end   = target.next_month.strftime("%Y-%m-%d")

    ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE TABLE IF NOT EXISTS #{name}
        PARTITION OF vendor_signals
        FOR VALUES FROM ('#{range_start}') TO ('#{range_end}');
    SQL

    Rails.logger.tagged("partition_manager") do
      Rails.logger.info("created partition #{name} (#{range_start} → #{range_end})")
    end
    ::Audit::Recorder.record(
      actor: "PartitionManagerJob",
      action: "partition#create",
      entity_type: "VendorSignalsPartition",
      entity_id: name,
      after_state: { range_start: range_start, range_end: range_end }
    )
  end

  def drop_expired_partitions(now)
    retention_months = ENV.fetch(
      "VENDOR_SIGNALS_RETENTION_MONTHS",
      DEFAULT_RETENTION_MONTHS.to_s
    ).to_i
    cutoff = (now.beginning_of_month - retention_months.months).to_date

    existing_partitions.each do |name|
      m = name.match(PARTITION_NAME_REGEX)
      next unless m

      partition_month = Date.new(m[1].to_i, m[2].to_i, 1)
      next if partition_month >= cutoff

      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{name} CASCADE")
      Rails.logger.tagged("partition_manager") do
        Rails.logger.info("dropped expired partition #{name} (retention=#{retention_months}mo)")
      end
      ::Audit::Recorder.record(
        actor: "PartitionManagerJob",
        action: "partition#drop",
        entity_type: "VendorSignalsPartition",
        entity_id: name,
        before_state: { partition_month: partition_month.iso8601 }
      )
    end
  end

  def partition_exists?(name)
    ActiveRecord::Base.connection.select_value(
      "SELECT 1 FROM pg_tables WHERE tablename = '#{name}'"
    ).present?
  end

  def partition_name_for(time)
    "vendor_signals_#{time.strftime('%Y_%m')}"
  end

  # Returns the list of month-suffixed partition tables. Excludes the
  # catch-all `vendor_signals_default` partition — that one is never dropped.
  def existing_partitions
    ActiveRecord::Base.connection.select_values(<<~SQL)
      SELECT tablename FROM pg_tables
       WHERE tablename ~ '^vendor_signals_[0-9]{4}_[0-9]{2}$'
    SQL
  end
end
