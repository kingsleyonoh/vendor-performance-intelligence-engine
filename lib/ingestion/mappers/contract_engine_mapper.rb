# frozen_string_literal: true

module Ingestion
  module Mappers
    # Translates Contract Lifecycle Engine surfaces into VPI signal payloads
    # consumable by `Ingestion::SignalIngester`.
    #
    # PRD §6 (Contract Lifecycle signals) — five canonical signal codes
    # (mirror `db/seeds/signal_definitions.yml`):
    #   - contract.obligation_breach_count_90d (count)
    #   - contract.sla_miss_ratio_30d          (rate)
    #   - contract.renewal_at_risk             (boolean)
    #   - contract.auto_renewal_flag           (boolean)
    #   - contract.obligation_deadline_missed_count_30d (count)
    #
    # Two entry points:
    #   - `map_stats(...)` — REST `/api/stats` aggregate (called by backfill job)
    #   - `map_event(...)` — single NATS JetStream message body (called by consumer)
    #
    # Pure function: no DB, no HTTP, no time-of-day dependence.
    class ContractEngineMapper
      METRIC_TO_SIGNAL = [
        { stat_key: "obligation_breach_count_90d",
          signal_code: "contract.obligation_breach_count_90d", window_days: 90, kind: :count },
        { stat_key: "sla_miss_ratio_30d",
          signal_code: "contract.sla_miss_ratio_30d",          window_days: 30, kind: :rate },
        { stat_key: "renewal_at_risk",
          signal_code: "contract.renewal_at_risk",             window_days: 30, kind: :boolean },
        { stat_key: "auto_renewal_flag",
          signal_code: "contract.auto_renewal_flag",           window_days: 30, kind: :boolean },
        { stat_key: "obligation_deadline_missed_count_30d",
          signal_code: "contract.obligation_deadline_missed_count_30d",
          window_days: 30, kind: :count }
      ].freeze

      # `renewal_risk_level` (0..3) is reduced to the boolean
      # `contract.renewal_at_risk` (true when level >= 2).
      RENEWAL_RISK_THRESHOLD = 2

      # ------------------------------------------------------------------
      # REST /api/stats → array of signal payloads
      # ------------------------------------------------------------------
      def self.map_stats(stats:, source:, vendor:, recorded_at: Time.now.utc)
        return [] if stats.nil? || stats.empty?
        normalized = stats.transform_keys(&:to_s)

        # Promote `renewal_risk_level` into `renewal_at_risk` boolean for
        # consumer convenience — Contract Engine surfaces a 0..3 ordinal,
        # the engine's signal taxonomy is boolean.
        if normalized.key?("renewal_risk_level") && !normalized.key?("renewal_at_risk")
          level = normalized["renewal_risk_level"].to_i
          normalized["renewal_at_risk"] = level >= RENEWAL_RISK_THRESHOLD
        end

        METRIC_TO_SIGNAL.filter_map do |entry|
          next unless normalized.key?(entry[:stat_key])
          window_start = (recorded_at - (entry[:window_days] * 86_400)).utc
          window_end   = recorded_at.utc

          signal_payload(
            signal_code: entry[:signal_code],
            kind: entry[:kind],
            value: normalized[entry[:stat_key]],
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
      # NATS event body → single signal payload
      # ------------------------------------------------------------------
      # Expected shape (JSON body of a `contract.obligation.*` message):
      #   {
      #     "tenant_slug": "acme-gmbh-de",
      #     "vendor_ref": { "tax_id": "DE-123" } | "string",
      #     "signal_code": "contract.obligation_breach_count_90d",
      #     "source_event_id": "nats:<uuid>",
      #     "value_numeric": 4,                  # OR value_boolean
      #     "recorded_at": "2026-04-23T...Z",
      #     "window_start": "...", "window_end": "..."
      #   }
      def self.map_event(event:, source_id: nil)
        body = event.is_a?(Hash) ? event.transform_keys(&:to_s) : {}
        signal_code = body["signal_code"].to_s
        return nil if signal_code.empty?

        recorded_at  = parse_time(body["recorded_at"]) || Time.now.utc
        window_start = parse_time(body["window_start"]) || (recorded_at - 30 * 86_400)
        window_end   = parse_time(body["window_end"])   || recorded_at

        payload = {
          vendor_ref: body["vendor_ref"],
          signal_code: signal_code,
          source_system: "contract_engine",
          source_event_id: body["source_event_id"].to_s,
          recorded_at: recorded_at.iso8601,
          window_start: window_start.iso8601,
          window_end: window_end.iso8601,
          context: { ingestion_source_id: source_id, subject: body["subject"] }.compact
        }

        if body.key?("value_boolean")
          payload[:value_boolean] = !!body["value_boolean"]
        elsif body.key?("value_numeric")
          payload[:value_numeric] = body["value_numeric"].to_f
        end

        payload
      end

      # ------------------------------------------------------------------
      # Internals
      # ------------------------------------------------------------------

      def self.signal_payload(signal_code:, kind:, value:, source:, vendor:, stat_key:,
                              recorded_at:, window_start:, window_end:)
        vendor_ref = if vendor.tax_id.present?
                       { "tax_id" => vendor.tax_id, "normalized_name" => vendor.normalized_name }
                     else
                       { "normalized_name" => vendor.normalized_name }
                     end

        base = {
          vendor_ref: vendor_ref,
          signal_code: signal_code,
          source_system: "contract_engine",
          source_event_id: "contract_engine:#{vendor.id}:#{stat_key}:#{recorded_at.to_i}",
          recorded_at: recorded_at.iso8601,
          window_start: window_start.iso8601,
          window_end: window_end.iso8601,
          context: { stat_key: stat_key, ingestion_source_id: source&.id, vendor_id: vendor.id }
        }

        case kind
        when :boolean
          base[:value_boolean] = !!value
        when :count, :rate
          base[:value_numeric] = value.to_f
        end
        base
      end

      def self.parse_time(value)
        return nil if value.nil? || value.to_s.empty?
        return value if value.is_a?(Time)
        Time.iso8601(value.to_s).utc
      rescue ArgumentError
        nil
      end
    end
  end
end
