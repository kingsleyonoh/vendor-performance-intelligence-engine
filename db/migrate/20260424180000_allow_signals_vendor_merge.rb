# frozen_string_literal: true

# Relax the `vendor_signals_enforce_append_only` trigger to permit a
# vendor_id change ONLY while a session-scoped GUC is set to 'true'. This
# is the narrowest possible escape hatch for PRD §5.2 — vendor merge —
# while keeping the append-only invariant intact for every other caller.
#
# The merger (`Ingestion::VendorMerger`) SETs the GUC inside a transaction,
# performs the UPDATE, and the GUC resets at transaction end. No other
# caller may set this variable — guarded by code review + grep.
#
# Also adds a `merged_at` column to `vendor_signals` so the merger can
# stamp the rows it moved without adding a second column mutation path.
class AllowSignalsVendorMerge < ActiveRecord::Migration[8.0]
  def up
    # Add merged_at column (nullable; stamped only on rows moved by a merge)
    execute <<~SQL
      ALTER TABLE vendor_signals ADD COLUMN IF NOT EXISTS merged_at TIMESTAMPTZ NULL;
    SQL

    # Re-register the trigger function. The new body permits:
    #   - vendor_id change when current_setting('vpi.signals_merge_mode', true) = 'true'
    #   - merged_at change when the same GUC is set (so the merger can stamp it)
    # All other columns remain locked, and DELETE remains blocked entirely.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION vendor_signals_enforce_append_only()
      RETURNS TRIGGER AS $$
      DECLARE
        merge_mode TEXT;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'vendor_signals is append-only; DELETE is not permitted (row id=%)', OLD.id;
        END IF;

        IF TG_OP = 'UPDATE' THEN
          merge_mode := current_setting('vpi.signals_merge_mode', true);

          -- In merge mode: only vendor_id, merged_at, and status may change.
          -- Every other locked column must still be unchanged.
          IF merge_mode = 'true' THEN
            IF NEW.id IS DISTINCT FROM OLD.id
               OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
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
              RAISE EXCEPTION 'vendor_signals merge: only vendor_id, merged_at, and status may change (row id=%)', OLD.id;
            END IF;

            -- Status transitions still governed in merge mode.
            IF NEW.status IS DISTINCT FROM OLD.status THEN
              IF NOT (
                (OLD.status = 'raw' AND NEW.status IN ('normalized','rejected'))
                OR (OLD.status = 'normalized' AND NEW.status IN ('scored','superseded'))
              ) THEN
                RAISE EXCEPTION 'vendor_signals: illegal status transition % -> %', OLD.status, NEW.status;
              END IF;
            END IF;

            RETURN NEW;
          END IF;

          -- Non-merge mode: lock vendor_id + merged_at + every other column.
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
             OR NEW.created_at IS DISTINCT FROM OLD.created_at
             OR NEW.merged_at IS DISTINCT FROM OLD.merged_at THEN
            RAISE EXCEPTION 'vendor_signals is append-only; only `status` may be updated (row id=%)', OLD.id;
          END IF;

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
  end

  def down
    execute <<~SQL
      ALTER TABLE vendor_signals DROP COLUMN IF EXISTS merged_at;
    SQL

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
  end
end
