# frozen_string_literal: true

# ingestion_runs — PRD §4. Audit ledger of every ingestion attempt
# (full backfill, incremental pull, webhook event, manual trigger).
# `retry_payload` carries the resumable cursor so a 5xx mid-pull can be
# resumed on the next cycle without re-fetching the entire window.
#
# Indexes:
#   - (tenant_id, ingestion_source_id, started_at DESC) — primary feed query
#   - (tenant_id, status)                                — stale-pull detection
class CreateIngestionRuns < ActiveRecord::Migration[8.0]
  MODES    = %w[full_backfill incremental webhook_event manual].freeze
  STATUSES = %w[running succeeded failed partial].freeze

  def change
    create_table :ingestion_runs, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.references :ingestion_source, type: :uuid, null: false, foreign_key: true

      t.text :mode, null: false
      t.text :status, null: false, default: "running"

      t.integer :signals_attempted, null: false, default: 0
      t.integer :signals_stored,    null: false, default: 0
      t.integer :signals_rejected,  null: false, default: 0
      t.integer :signals_deduped,   null: false, default: 0

      t.text  :error_summary
      t.jsonb :retry_payload, null: false, default: {}

      t.timestamptz :started_at,  null: false
      t.timestamptz :finished_at

      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE ingestion_runs
        ADD CONSTRAINT ingestion_runs_mode_chk
        CHECK (mode IN ('#{MODES.join("','")}'))
    SQL

    execute <<~SQL
      ALTER TABLE ingestion_runs
        ADD CONSTRAINT ingestion_runs_status_chk
        CHECK (status IN ('#{STATUSES.join("','")}'))
    SQL

    add_index :ingestion_runs, [:tenant_id, :ingestion_source_id, :started_at],
              order: { started_at: :desc },
              name: "ingestion_runs_tenant_source_started_idx"
    add_index :ingestion_runs, [:tenant_id, :status],
              name: "ingestion_runs_tenant_status_idx"
  end
end
