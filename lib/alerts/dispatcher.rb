# frozen_string_literal: true

module Alerts
  # Alerts::Dispatcher — PRD §5, §7, §13.2.
  #
  # Wired to ScoreRecomputeJob's `band_crossing_hook` from
  # `config/initializers/alert_dispatcher.rb`. On every score recompute that
  # crossed bands:
  #   1. detect direction (escalation | improvement | no-change → bail)
  #   2. dedup against existing alerts in ALERT_DEDUP_WINDOW_HOURS
  #   3. capture frozen DeliveryPayload via `Alerts::CapturePayload`
  #   4. INSERT risk_alert with status='pending'
  #   5. enqueue HubDispatchJob
  #
  # The scorer itself does no I/O of its own — this module is the only
  # place band-crossings turn into side-effects.
  class Dispatcher
    BAND_RANK = { "low" => 0, "medium" => 1, "high" => 2, "critical" => 3 }.freeze

    class << self
      # Hook entry point. Called from `ScoreRecomputeJob.band_crossing_hook`
      # after a fresh `vendor_scores` row is inserted. Returns the new
      # RiskAlert, or nil if no alert was created (no band change, dedup,
      # or unique-constraint race).
      def on_band_crossing(score:, previous_band:)
        return nil if score.nil?
        return nil if previous_band.to_s.empty?

        direction = direction_for(previous_band: previous_band, new_band: score.band)
        return nil if direction.nil?

        return nil if duplicate_within_window?(score)

        payload = ::Alerts::CapturePayload.call(vendor_score: score)

        alert = ::RiskAlert.create!(
          tenant_id: score.tenant_id,
          vendor_id: score.vendor_id,
          previous_band: previous_band.to_s,
          new_band: score.band,
          previous_score: previous_composite_for(score)&.to_f || score.composite_score.to_f,
          new_score: score.composite_score.to_f,
          direction: direction,
          triggered_by_score: score.id,
          status: "pending",
          delivery_payload: payload
        )

        ::Alerts::HubDispatchJob.perform_later(alert.id)

        alert
      rescue ::ActiveRecord::RecordNotUnique
        # The (tenant, vendor, score) UNIQUE index fired — another worker
        # already inserted the alert for this exact score. Idempotent no-op.
        nil
      end

      private

      def direction_for(previous_band:, new_band:)
        prev = BAND_RANK[previous_band.to_s]
        curr = BAND_RANK[new_band.to_s]
        return nil if prev.nil? || curr.nil?
        return nil if prev == curr

        curr > prev ? "escalation" : "improvement"
      end

      def duplicate_within_window?(score)
        cutoff = Time.now.utc - dedup_window_hours.hours
        ::RiskAlert
          .where(tenant_id: score.tenant_id, vendor_id: score.vendor_id)
          .where("created_at >= ?", cutoff)
          .exists?
      end

      def dedup_window_hours
        ENV.fetch("ALERT_DEDUP_WINDOW_HOURS", "24").to_i
      end

      def previous_composite_for(score)
        ::VendorScore
          .where(tenant_id: score.tenant_id, vendor_id: score.vendor_id)
          .where("computed_at < ?", score.computed_at)
          .order(computed_at: :desc)
          .limit(1)
          .pick(:composite_score)
      end
    end
  end
end
