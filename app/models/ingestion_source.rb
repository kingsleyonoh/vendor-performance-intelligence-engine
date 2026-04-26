# frozen_string_literal: true

# IngestionSource — PRD §4. One row per (tenant, source_system) tuple.
# Holds the per-tenant configuration for an upstream signal producer
# (Invoice Recon, Webhook Engine, Contract Lifecycle, Transaction Recon,
# RAG Platform, manual). Feature-flag aware via `is_enabled` — when off,
# cron jobs skip this source (PRD §2.2 standalone-first).
#
# `connection_config` is jsonb. Secrets MUST NEVER be stored inline —
# config references env keys instead (`{base_url_env: "INVOICE_RECON_URL",
# api_key_env: "INVOICE_RECON_API_KEY"}`).
class IngestionSource < ApplicationRecord
  self.table_name = "ingestion_sources"

  SOURCE_SYSTEMS = %w[invoice_recon webhook_engine contract_engine recon_engine rag_platform manual].freeze
  PULL_MODES     = %w[periodic webhook_push manual].freeze

  belongs_to :tenant
  has_many :ingestion_runs, dependent: :destroy

  validates :source_system, presence: true, inclusion: { in: SOURCE_SYSTEMS }
  validates :pull_mode,    presence: true, inclusion: { in: PULL_MODES }
  validates :source_system, uniqueness: { scope: :tenant_id }

  scope :enabled, -> { where(is_enabled: true) }
end
