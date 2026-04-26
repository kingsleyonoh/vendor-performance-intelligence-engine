# frozen_string_literal: true

# ScoreRecomputeJob — PRD §5.4, §7. Wraps `Scoring::CompositeScorer.call` for
# a single vendor within a tenant. Triggered by every successful signal
# insert (via `Ingestion::SignalIngester.post_insert_hook`, wired in
# `config/initializers/signal_ingester_hooks.rb`). Also invoked by
# `AllVendorsRescoreJob` (Phase 3) and the scoring-rule preview endpoint.
#
# Contract (positional args for Sidekiq-friendly serialization):
#   ScoreRecomputeJob.perform_later(vendor_id, tenant_id)
#
# Inside the job:
#   1. Lookup Tenant by id (raises ActiveRecord::RecordNotFound on bad input).
#   2. Bind Current.tenant for the duration so downstream scoped reads work.
#   3. Invoke CompositeScorer. If no signals in window → log + no-op.
#   4. Log a band-crossing line when the new band differs from the previous
#      row's band. Phase 2 wires this into the alert router; Phase 1 only
#      logs (standalone-first).
#   5. Reset Current.tenant in an ensure block.
#
# Idempotency: safe to call multiple times — every call inserts a fresh
# `vendor_scores` row (scores are derived, never patched — invariant 3).
class ScoreRecomputeJob < ApplicationJob
  queue_as :default

  # Class-level accessor so Phase 2 can swap in an alerts-dispatching
  # proc without monkey-patching the job. Phase 1 default is a no-op.
  class << self
    attr_accessor :band_crossing_hook
  end
  self.band_crossing_hook = ->(_score, _previous_band) { nil }

  def perform(vendor_id, tenant_id)
    tenant = Tenant.find(tenant_id)

    previous_band = previous_band_for(tenant_id: tenant_id, vendor_id: vendor_id)

    result = nil
    Current.set(tenant: tenant) do
      result = ::Scoring::CompositeScorer.call(vendor_id: vendor_id, tenant: tenant)
    end

    if result.nil?
      Rails.logger.tagged("scoring") do
        Rails.logger.info(
          "ScoreRecomputeJob: no signals in window for vendor=#{vendor_id} tenant=#{tenant_id}"
        )
      end
      return nil
    end

    log_band_crossing(result, previous_band)
    self.class.band_crossing_hook&.call(result, previous_band)

    result
  end

  private

  # Read the band of the most recent prior score BEFORE compute, so the
  # crossing detector sees the true previous band rather than the new one
  # just inserted by CompositeScorer.
  def previous_band_for(tenant_id:, vendor_id:)
    VendorScore
      .where(tenant_id: tenant_id, vendor_id: vendor_id)
      .order(computed_at: :desc)
      .limit(1)
      .pick(:band)
  end

  def log_band_crossing(score, previous_band)
    crossing = ::Scoring::CompositeScorer.detect_band_crossing(
      previous_band: previous_band,
      new_band: score.band
    )
    return if crossing.nil?

    Rails.logger.tagged("scoring") do
      Rails.logger.info(
        "band_crossing: vendor_id=#{score.vendor_id} tenant_id=#{score.tenant_id} " \
          "from=#{crossing[:from]} to=#{crossing[:to]} direction=#{crossing[:direction]}"
      )
    end
  end
end
