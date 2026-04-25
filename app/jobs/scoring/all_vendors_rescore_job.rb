# frozen_string_literal: true

module Scoring
  # AllVendorsRescoreJob — PRD §7, §13.3.
  #
  # Daily 02:00 UTC fan-out: enqueues `ScoreRecomputeJob` for every
  # active vendor across every tenant. When invoked with `tenant_id:`,
  # narrows fan-out to that tenant only — used by Phase 3 scoring-rule
  # activation hook (`ScoringRulesController.on_activation_hooks`) and
  # operator-driven "Rescore now" actions.
  #
  # Skips vendors with `status` IN `(terminated, merged)` — derived
  # scores never apply to them.
  #
  # Standalone-first: works regardless of any ecosystem flag. Pure
  # internal Sidekiq fan-out.
  #
  # Audit: one `scoring.bulk_rescore` row per tenant per run; before/
  # after_state captures the enqueued vendor count for traceability.
  class AllVendorsRescoreJob < ApplicationJob
    queue_as :default

    # @param tenant_id [String, nil] when present, fan-out only this tenant.
    #   When nil (the cron path), iterates every tenant in the system.
    def perform(tenant_id: nil)
      tenant_ids = tenant_id ? [tenant_id] : Tenant.where(is_active: true).pluck(:id)

      tenant_ids.each do |tid|
        process_tenant(tid)
      end
    end

    private

    def process_tenant(tenant_id)
      vendor_ids = Vendor.where(tenant_id: tenant_id, status: "active").pluck(:id)
      return if vendor_ids.empty?

      vendor_ids.each do |vid|
        ScoreRecomputeJob.perform_later(vid, tenant_id)
      end

      Audit::Recorder.record(
        actor: "system:all_vendors_rescore",
        action: "scoring.bulk_rescore",
        entity_type: "Tenant",
        entity_id: tenant_id,
        tenant_id: tenant_id,
        after_state: { enqueued_vendor_count: vendor_ids.size }
      )
    rescue StandardError => e
      Rails.logger.error("[all_vendors_rescore] tenant=#{tenant_id} failed: #{e.class}: #{e.message}")
    end
  end
end
