# frozen_string_literal: true

module Ingestion
  module Mappers
    # Translates a Webhook Ingestion Engine `/api/stats` aggregate response
    # into VPI signal payloads consumable by `Ingestion::SignalIngester`.
    #
    # PRD §6 (Webhook Engine signals): integration-reliability metrics are
    # computed upstream as 24-hour aggregates and surfaced via /api/stats.
    # The mapper turns that aggregate hash into one signal per metric,
    # tagged to the upstream `source_id` (treated as the vendor identity
    # since Webhook Engine sources map 1:1 to vendors in PRD §6).
    #
    # The mapper is a pure function — no DB, no HTTP, no time-of-day
    # dependence. Time-of-day is captured at the call site so the job
    # can tag both `recorded_at` and `window_start/window_end` consistently.
    class WebhookEngineMapper
      # Mapping table: metric key in stats hash → (signal_code, value_type).
      # PRD §4.4 / signal_definitions.yml — these four codes are
      # registered in the system signal catalog.
      METRIC_TO_SIGNAL = [
        # success_rate_24h is the inverse — VPI signal is a "failure rate".
        # Webhook Engine returns success_rate; we'd typically derive
        # dead_letter_rate_7d from a separate longer-window stat. For the
        # 24h batch, we use dead_letter_count_24h directly (count) and the
        # daily ingestion-lag p95 falls under a 7-day rolling stat
        # downstream — out of scope for the per-batch mapper.
        { stat_key: "dead_letter_count_24h",
          signal_code: "webhook.schema_drift_count_30d",
          value_kind: :numeric_count,
          remap_to_signal_code: nil },
        { stat_key: "schema_drift_24h",
          signal_code: "webhook.schema_drift_count_30d",
          value_kind: :numeric_count },
        { stat_key: "retry_avg_24h",
          signal_code: "webhook.avg_retry_count_7d",
          value_kind: :numeric_count }
      ].freeze

      # Public API.
      #
      # @param stats [Hash] body returned by /api/stats (e.g.
      #   `{"success_rate_24h"=>0.97, "dead_letter_count_24h"=>3, ...}`)
      # @param source [IngestionSource]
      # @param recorded_at [Time]
      # @return [Array<Hash>] one payload per mapped metric, ready for
      #   `Ingestion::SignalIngester.call`
      def self.map_stats(stats:, source:, recorded_at: Time.now.utc)
        return [] if stats.nil? || stats.empty?

        normalized = stats.transform_keys(&:to_s)
        window_start = (recorded_at - (24 * 3600)).utc
        window_end   = recorded_at.utc

        # Always emit the dead-letter rate as the canonical 7-day signal —
        # webhook.dead_letter_rate_7d. We approximate from 24h aggregates
        # by treating the 24h success rate as a window proxy. The upstream
        # is the long-term source of truth; Phase 3 enriches with the
        # 7-day endpoint when Webhook Engine exposes it.
        payloads = []

        if normalized.key?("success_rate_24h")
          rate = (1.0 - normalized["success_rate_24h"].to_f).clamp(0.0, 1.0)
          payloads << signal_payload(
            signal_code: "webhook.dead_letter_rate_7d",
            value_numeric: rate,
            source: source,
            stat_key: "dead_letter_rate_7d",
            recorded_at: recorded_at,
            window_start: window_start, window_end: window_end
          )
        end

        if normalized.key?("retry_avg_24h")
          payloads << signal_payload(
            signal_code: "webhook.avg_retry_count_7d",
            value_numeric: normalized["retry_avg_24h"].to_f,
            source: source,
            stat_key: "retry_avg_24h",
            recorded_at: recorded_at,
            window_start: window_start, window_end: window_end
          )
        end

        if normalized.key?("schema_drift_24h")
          payloads << signal_payload(
            signal_code: "webhook.schema_drift_count_30d",
            value_numeric: normalized["schema_drift_24h"].to_f,
            source: source,
            stat_key: "schema_drift_24h",
            recorded_at: recorded_at,
            window_start: window_start, window_end: window_end
          )
        end

        payloads
      end

      # ------------------------------------------------------------------

      def self.signal_payload(signal_code:, value_numeric:, source:, stat_key:,
                              recorded_at:, window_start:, window_end:)
        # Webhook Engine sources map 1:1 to vendors in this engine.
        # The source.connection_config carries a `vendor_ref` block when
        # the operator has wired the source to a specific vendor; absent
        # that, we use a deterministic source-id-based ref so the signal
        # at least lands on a stable vendor row.
        vendor_ref = source.connection_config.is_a?(Hash) ?
          (source.connection_config["vendor_ref"] || source.connection_config[:vendor_ref] || {}) :
          {}
        vendor_ref = vendor_ref.transform_keys(&:to_s) if vendor_ref.is_a?(Hash)

        # Fall back to a synthetic identity tied to the source — keeps the
        # SignalValidator MISSING_VENDOR_REF rule happy and the resolver
        # creates a stable vendor row keyed off the source's display name.
        if vendor_ref.empty? || (vendor_ref["tax_id"].to_s.strip.empty? &&
                                   vendor_ref["normalized_name"].to_s.strip.empty? &&
                                   vendor_ref["source_system_ref"].to_s.strip.empty?)
          vendor_ref = {
            "source_system_ref" => source.id.to_s,
            "normalized_name" => "webhook-source-#{source.id}"
          }
        end

        {
          vendor_ref: vendor_ref,
          signal_code: signal_code,
          source_system: "webhook_engine",
          source_event_id: "webhook_engine:#{source.id}:#{stat_key}:#{recorded_at.to_i}",
          value_numeric: value_numeric.to_f,
          recorded_at: recorded_at.iso8601,
          window_start: window_start.iso8601,
          window_end: window_end.iso8601,
          context: { stat_key: stat_key, ingestion_source_id: source.id }
        }
      end
    end
  end
end
