# frozen_string_literal: true

# Adds `monitor_state` jsonb column to `ingestion_sources` (PRD §7b, §13.2).
# Used by `Monitors::StaleIngestionMonitorJob` to track the last time a
# stale Hub event was emitted so re-emits are throttled (idempotent within
# 6h to avoid alert flooding).
#
# Shape: `{"last_stale_emitted_at": "<iso8601>"}`
# Defaults to `{}` so existing rows are simply un-emitted-yet.
class AddMonitorStateToIngestionSources < ActiveRecord::Migration[8.0]
  def change
    add_column :ingestion_sources, :monitor_state, :jsonb, null: false, default: {}
  end
end
