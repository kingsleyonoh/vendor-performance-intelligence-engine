# frozen_string_literal: true

# ingestion_sources — PRD §4. Per-tenant per-source configuration for the
# upstream signal producers (Invoice Recon, Webhook Engine, Contract
# Lifecycle, Transaction Recon, RAG Platform, manual). Feature-flag aware
# via `is_enabled` (PRD §2.2 standalone-first invariant).
#
# Indexes:
#   - (tenant_id, source_system) UNIQUE — at most one source per system per tenant
#   - (tenant_id, is_enabled)             — drives the cron query for active sources
class CreateIngestionSources < ActiveRecord::Migration[8.0]
  SOURCE_SYSTEMS = %w[invoice_recon webhook_engine contract_engine recon_engine rag_platform manual].freeze
  PULL_MODES     = %w[periodic webhook_push manual].freeze

  def change
    create_table :ingestion_sources, id: :uuid, default: "gen_random_uuid()" do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true

      t.text    :source_system, null: false
      t.boolean :is_enabled, null: false, default: false
      t.jsonb   :connection_config, null: false, default: {}
      t.text    :pull_mode, null: false, default: "periodic"
      t.integer :pull_interval_minutes, default: 15

      t.timestamptz :last_successful_pull
      t.timestamptz :last_attempted_pull
      t.text        :last_failure_reason

      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE ingestion_sources
        ADD CONSTRAINT ingestion_sources_source_system_chk
        CHECK (source_system IN ('#{SOURCE_SYSTEMS.join("','")}'))
    SQL

    execute <<~SQL
      ALTER TABLE ingestion_sources
        ADD CONSTRAINT ingestion_sources_pull_mode_chk
        CHECK (pull_mode IN ('#{PULL_MODES.join("','")}'))
    SQL

    add_index :ingestion_sources, [:tenant_id, :source_system],
              unique: true,
              name: "ingestion_sources_tenant_system_uidx"
    add_index :ingestion_sources, [:tenant_id, :is_enabled],
              name: "ingestion_sources_tenant_enabled_idx"
  end
end
