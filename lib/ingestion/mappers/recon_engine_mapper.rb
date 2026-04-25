# frozen_string_literal: true

module Ingestion
  module Mappers
    # Translates a Transaction Reconciliation Engine `/api/v1/stats`
    # aggregate response into VPI signal payloads consumable by
    # `Ingestion::SignalIngester`.
    #
    # PRD §6 (Recon signals): transactional metrics computed upstream as
    # rolling-window aggregates. The mapper turns that aggregate hash
    # into one signal per metric tagged to the supplied vendor.
    #
    # The mapper is a pure function — no DB, no HTTP, no time-of-day
    # dependence. The four signal codes mapped here match the PRD §4.4
    # `signal_definitions` catalog entries for source_system='recon_engine'.
    class ReconEngineMapper
      # Mapping table: stat_key → (signal_code, window_days).
      METRIC_TO_SIGNAL = [
        { stat_key: "discrepancy_rate_30d",        signal_code: "recon.discrepancy_rate_30d",        window_days: 30 },
        { stat_key: "unmatched_payment_count_7d",  signal_code: "recon.unmatched_payment_count_7d",  window_days: 7 },
        { stat_key: "reject_rate_30d",             signal_code: "recon.reject_rate_30d",             window_days: 30 },
        { stat_key: "late_settlement_count_90d",   signal_code: "recon.late_settlement_count_90d",   window_days: 90 }
      ].freeze

      # Public API.
      #
      # @param stats [Hash] body returned by /api/v1/stats
      # @param source [IngestionSource]
      # @param vendor [Vendor]
      # @param recorded_at [Time]
      # @return [Array<Hash>] one payload per mapped metric
      def self.map_stats(stats:, source:, vendor:, recorded_at: Time.now.utc)
        return [] if stats.nil? || stats.empty?
        normalized = stats.transform_keys(&:to_s)

        METRIC_TO_SIGNAL.filter_map do |entry|
          next unless normalized.key?(entry[:stat_key])

          window_start = (recorded_at - (entry[:window_days] * 86_400)).utc
          window_end   = recorded_at.utc

          signal_payload(
            signal_code: entry[:signal_code],
            value_numeric: normalized[entry[:stat_key]].to_f,
            source: source,
            vendor: vendor,
            stat_key: entry[:stat_key],
            recorded_at: recorded_at,
            window_start: window_start,
            window_end: window_end
          )
        end
      end

      # ------------------------------------------------------------------

      def self.signal_payload(signal_code:, value_numeric:, source:, vendor:, stat_key:,
                              recorded_at:, window_start:, window_end:)
        # Vendor identity for the resolver. Prefer tax_id (priority 1.00),
        # fall back to the canonical/normalized name.
        vendor_ref = if vendor.tax_id.present?
                       { "tax_id" => vendor.tax_id, "normalized_name" => vendor.normalized_name }
                     else
                       { "normalized_name" => vendor.normalized_name }
                     end

        {
          vendor_ref: vendor_ref,
          signal_code: signal_code,
          source_system: "recon_engine",
          source_event_id: "recon_engine:#{vendor.id}:#{stat_key}:#{recorded_at.to_i}",
          value_numeric: value_numeric.to_f,
          recorded_at: recorded_at.iso8601,
          window_start: window_start.iso8601,
          window_end: window_end.iso8601,
          context: { stat_key: stat_key, ingestion_source_id: source.id, vendor_id: vendor.id }
        }
      end
    end
  end
end
