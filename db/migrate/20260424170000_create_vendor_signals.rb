# frozen_string_literal: true

# vendor_signals — PRD §4.5. Append-only time-series; partitioned by month on
# `recorded_at` using PostgreSQL native range partitioning. PRD originally
# mentioned pg_partman; we chose native declarative partitioning to avoid a
# custom Postgres image — PartitionManagerJob (future batch) creates the next
# month's partition nightly via a simple CREATE TABLE...PARTITION OF...
#
# Invariant 3 (PRD §2): signals are append-only facts. DB-level trigger blocks
# UPDATE of any column EXCEPT `status` (which may only transition along the
# legal edges) and blocks all DELETEs. Model layer re-asserts the same rule.
class CreateVendorSignals < ActiveRecord::Migration[8.0]
  def up
    # Parent partitioned table — uses raw SQL because Rails schema DSL does
    # not emit PARTITION BY RANGE. `id` alone is not a valid PK on a
    # partitioned table — the partition key (recorded_at) must be part of
    # the unique/PK index per Postgres requirement.
    execute <<~SQL
      CREATE TABLE vendor_signals (
        id              UUID NOT NULL DEFAULT gen_random_uuid(),
        tenant_id       UUID NOT NULL,
        vendor_id       UUID NOT NULL,
        signal_code     TEXT NOT NULL,
        source_system   TEXT NOT NULL,
        source_event_id TEXT,
        value_numeric   NUMERIC(20,4),
        value_boolean   BOOLEAN,
        context         JSONB NOT NULL DEFAULT '{}'::jsonb,
        window_start    TIMESTAMPTZ,
        window_end      TIMESTAMPTZ,
        recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        status          TEXT NOT NULL DEFAULT 'normalized',
        rejection_reason TEXT,
        supersedes_id   UUID,
        created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (id, recorded_at),
        CONSTRAINT vendor_signals_tenant_fk FOREIGN KEY (tenant_id) REFERENCES tenants(id),
        CONSTRAINT vendor_signals_vendor_fk FOREIGN KEY (vendor_id) REFERENCES vendors(id),
        CONSTRAINT vendor_signals_status_chk
          CHECK (status IN ('raw','normalized','scored','rejected','superseded')),
        CONSTRAINT vendor_signals_source_system_chk
          CHECK (source_system IN ('invoice_recon','webhook_engine','contract_engine','recon_engine','rag_platform','manual')),
        CONSTRAINT vendor_signals_value_xor_chk
          CHECK (
            (value_numeric IS NOT NULL AND value_boolean IS NULL)
            OR (value_boolean IS NOT NULL AND value_numeric IS NULL)
            OR (value_numeric IS NULL AND value_boolean IS NULL AND status = 'rejected')
          )
      ) PARTITION BY RANGE (recorded_at);
    SQL

    # Indexes must include the partition key column per Postgres rules if
    # they are unique. Non-unique indexes can exclude it — Postgres will
    # propagate them to child partitions automatically.
    execute <<~SQL
      CREATE INDEX vendor_signals_tenant_vendor_code_recorded_idx
        ON vendor_signals (tenant_id, vendor_id, signal_code, recorded_at DESC);
    SQL

    execute <<~SQL
      CREATE UNIQUE INDEX vendor_signals_dedup_uidx
        ON vendor_signals (tenant_id, source_system, source_event_id, recorded_at)
        WHERE source_event_id IS NOT NULL;
    SQL

    execute <<~SQL
      CREATE INDEX vendor_signals_tenant_status_idx
        ON vendor_signals (tenant_id, status);
    SQL

    execute <<~SQL
      CREATE INDEX vendor_signals_tenant_signal_code_recorded_idx
        ON vendor_signals (tenant_id, signal_code, recorded_at DESC);
    SQL

    # Initial partitions: current month, next month, and a catch-all default
    # partition for any row landing outside the live range (defensive —
    # should not happen in practice once PartitionManagerJob is running).
    now = Time.now.utc
    current_start = Time.utc(now.year, now.month, 1)
    next_start = current_start.next_month
    following_start = next_start.next_month

    execute partition_ddl(current_start, next_start)
    execute partition_ddl(next_start, following_start)
    execute <<~SQL
      CREATE TABLE vendor_signals_default
        PARTITION OF vendor_signals DEFAULT;
    SQL

    # Append-only enforcement trigger — DB-layer defense-in-depth alongside
    # the model-layer guard in app/models/vendor_signal.rb. Blocks any
    # UPDATE that mutates a column other than `status`, and all DELETEs.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION vendor_signals_enforce_append_only()
      RETURNS TRIGGER AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'vendor_signals is append-only; DELETE is not permitted (row id=%)', OLD.id;
        END IF;

        IF TG_OP = 'UPDATE' THEN
          IF NEW.id IS DISTINCT FROM OLD.id
             OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
             OR NEW.vendor_id IS DISTINCT FROM OLD.vendor_id
             OR NEW.signal_code IS DISTINCT FROM OLD.signal_code
             OR NEW.source_system IS DISTINCT FROM OLD.source_system
             OR NEW.source_event_id IS DISTINCT FROM OLD.source_event_id
             OR NEW.value_numeric IS DISTINCT FROM OLD.value_numeric
             OR NEW.value_boolean IS DISTINCT FROM OLD.value_boolean
             OR NEW.context::text IS DISTINCT FROM OLD.context::text
             OR NEW.window_start IS DISTINCT FROM OLD.window_start
             OR NEW.window_end IS DISTINCT FROM OLD.window_end
             OR NEW.recorded_at IS DISTINCT FROM OLD.recorded_at
             OR NEW.supersedes_id IS DISTINCT FROM OLD.supersedes_id
             OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'vendor_signals is append-only; only `status` may be updated (row id=%)', OLD.id;
          END IF;

          -- status transitions: raw->normalized, raw->rejected, normalized->scored, normalized->superseded
          IF NEW.status IS DISTINCT FROM OLD.status THEN
            IF NOT (
              (OLD.status = 'raw' AND NEW.status IN ('normalized','rejected'))
              OR (OLD.status = 'normalized' AND NEW.status IN ('scored','superseded'))
            ) THEN
              RAISE EXCEPTION 'vendor_signals: illegal status transition % -> %', OLD.status, NEW.status;
            END IF;
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL

    execute <<~SQL
      CREATE TRIGGER vendor_signals_append_only_trg
        BEFORE UPDATE OR DELETE ON vendor_signals
        FOR EACH ROW EXECUTE FUNCTION vendor_signals_enforce_append_only();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS vendor_signals_append_only_trg ON vendor_signals;"
    execute "DROP FUNCTION IF EXISTS vendor_signals_enforce_append_only();"
    execute "DROP TABLE IF EXISTS vendor_signals CASCADE;"
  end

  private

  # Render a CREATE TABLE...PARTITION OF...FOR VALUES FROM...TO... statement
  # with month-suffixed naming matching the PRD example (vendor_signals_2026_04).
  def partition_ddl(from_time, to_time)
    name = "vendor_signals_#{from_time.strftime('%Y_%m')}"
    <<~SQL
      CREATE TABLE IF NOT EXISTS #{name}
        PARTITION OF vendor_signals
        FOR VALUES FROM ('#{from_time.strftime('%Y-%m-%d')}') TO ('#{to_time.strftime('%Y-%m-%d')}');
    SQL
  end
end
