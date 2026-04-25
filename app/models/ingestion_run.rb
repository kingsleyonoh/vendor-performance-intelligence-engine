# frozen_string_literal: true

# IngestionRun — PRD §4. One row per ingestion attempt. Tracks
# attempted/stored/rejected/deduped signal counts plus a resumable cursor
# in `retry_payload` (so a 5xx mid-pull can be resumed on the next cycle
# without re-fetching the entire window).
#
# Status lifecycle:
#   running → succeeded | failed | partial
class IngestionRun < ApplicationRecord
  self.table_name = "ingestion_runs"

  MODES    = %w[full_backfill incremental webhook_event manual].freeze
  STATUSES = %w[running succeeded failed partial].freeze

  belongs_to :tenant
  belongs_to :ingestion_source

  validates :mode,   presence: true, inclusion: { in: MODES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :started_at, presence: true
  validates :signals_attempted, :signals_stored, :signals_rejected, :signals_deduped,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :running,   -> { where(status: "running") }
  scope :succeeded, -> { where(status: "succeeded") }
  scope :failed,    -> { where(status: "failed") }
end
