# frozen_string_literal: true

module Monitors
  # StaleIngestionMonitorJob — PRD §7b, §13.2.
  #
  # Hourly cron. Detects ingestion sources where last_successful_pull
  # is older than 24h and emits a Hub event `ingestion.source_stale`
  # bound to the `vpi-ingestion-stale` Hub template.
  #
  # Idempotency:
  #   - Per-source 6h dedup window via
  #     `ingestion_sources.monitor_state.last_stale_emitted_at`. A
  #     subsequent run within 6h of a successful emit is silenced.
  #   - Sources never successfully pulled but freshly created (created_at
  #     within 24h) are NOT alerted — they're still doing first pull.
  #
  # Standalone-first (PRD §2.2):
  #   - Hub disabled → detection still runs, warning logged, no HTTP
  #     call, monitor_state NOT updated (so when Hub comes back online,
  #     the next run can fire). No alert flooding.
  #   - Disabled sources (is_enabled=false) are never alerted.
  STALE_THRESHOLD = 24.hours
  REEMIT_COOLDOWN = 6.hours

  class StaleIngestionMonitorJob < ApplicationJob
    queue_as :default

    EVENT_TYPE      = "ingestion.source_stale"
    SCHEMA_VERSION  = "vpi.ingestion_stale.v1"
    HUB_TEMPLATE_ID = "vpi-ingestion-stale"

    def perform
      now = Time.now.utc
      stale_sources(now: now).find_each do |source|
        next if recently_emitted?(source, now: now)

        payload = build_payload(source: source, now: now)

        if hub.enabled?
          result = hub.send_event(payload)
          if result[:status] == :sent
            stamp_emitted!(source, at: now, hub_event_id: result[:hub_event_id])
            record_audit(source: source, payload: payload, hub_event_id: result[:hub_event_id])
          else
            Rails.logger.warn("[stale_ingestion_monitor] hub send returned #{result[:status]} for source=#{source.id}")
          end
        else
          Rails.logger.warn(
            "[stale_ingestion_monitor] source=#{source.id} stale (#{payload[:source][:hours_stale]}h) — Hub disabled, no event emitted"
          )
        end
      rescue StandardError => e
        Rails.logger.error("[stale_ingestion_monitor] source=#{source.id} failed: #{e.class}: #{e.message}")
      end
    end

    private

    # All enabled sources that look stale. Two cases:
    #   1. last_successful_pull < now - 24h
    #   2. last_successful_pull IS NULL but created_at < now - 24h
    def stale_sources(now:)
      cutoff = now - STALE_THRESHOLD
      IngestionSource
        .where(is_enabled: true)
        .where(
          "last_successful_pull < :cutoff OR (last_successful_pull IS NULL AND created_at < :cutoff)",
          cutoff: cutoff
        )
    end

    def recently_emitted?(source, now:)
      raw = (source.monitor_state || {})["last_stale_emitted_at"]
      return false if raw.blank?

      last = Time.iso8601(raw.to_s).utc
      (now - last) < REEMIT_COOLDOWN
    rescue ArgumentError
      false
    end

    def build_payload(source:, now:)
      hours_stale = compute_hours_stale(source: source, now: now)
      {
        schema_version: SCHEMA_VERSION,
        event_type:     EVENT_TYPE,
        template_id:    HUB_TEMPLATE_ID,
        fired_at:       now.iso8601,
        tenant:         Tenants::CaptureSnapshot.call(source.tenant_id),
        source: {
          id: source.id,
          source_system: source.source_system,
          last_successful_pull: source.last_successful_pull&.iso8601,
          last_attempted_pull:  source.last_attempted_pull&.iso8601,
          last_failure_reason:  source.last_failure_reason,
          hours_stale:          hours_stale
        }
      }
    end

    def compute_hours_stale(source:, now:)
      basis = source.last_successful_pull || source.created_at
      return 0 if basis.nil?
      ((now - basis) / 3600.0).round(1)
    end

    def stamp_emitted!(source, at:, hub_event_id:)
      state = (source.monitor_state || {}).merge(
        "last_stale_emitted_at" => at.iso8601,
        "last_hub_event_id"     => hub_event_id
      )
      source.update_columns(monitor_state: state, updated_at: at)
    end

    def record_audit(source:, payload:, hub_event_id:)
      Audit::Recorder.record(
        actor: "system:stale_ingestion_monitor",
        action: "monitors.stale_ingestion#emit",
        entity_type: "IngestionSource",
        entity_id: source.id,
        tenant_id: source.tenant_id,
        after_state: { hub_event_id: hub_event_id, hours_stale: payload[:source][:hours_stale] }
      )
    rescue StandardError => e
      Rails.logger.error("[stale_ingestion_monitor] audit failed: #{e.class}: #{e.message}")
    end

    def hub
      Ecosystem::HubClient.instance || Ecosystem::HubClient.new
    end
  end
end
