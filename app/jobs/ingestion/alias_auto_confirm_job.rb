# frozen_string_literal: true

module Ingestion
  # AliasAutoConfirmJob — PRD §7, §7b, §13.3.
  #
  # Daily 04:00 UTC. Two responsibilities per tenant:
  #
  # 1. Auto-confirm exact tax_id matches: any `vendor_aliases` row with
  #    `is_confirmed=false` AND `confidence=1.00` flips to confirmed.
  #    Gated by `AUTO_CONFIRM_EXACT_TAXID` env (default true per PRD §14).
  #
  # 2. Operator queue alert: when remaining pending count > 20, emit a
  #    Hub event `alias.pending_review` bound to template
  #    `vpi-alias-review`. 24h dedup window via
  #    `tenants.settings.last_alias_review_emitted_at`. Standalone-first
  #    (Hub disabled → log + no state stamp so next run can re-emit when
  #    Hub comes back online).
  class AliasAutoConfirmJob < ApplicationJob
    queue_as :default

    EVENT_TYPE      = "alias.pending_review"
    SCHEMA_VERSION  = "vpi.alias.v1"
    HUB_TEMPLATE_ID = "vpi-alias-review"
    PENDING_THRESHOLD = 20
    REEMIT_COOLDOWN   = 24.hours
    SAMPLE_SIZE       = 5

    def perform
      now = Time.now.utc
      Tenant.where(is_active: true).find_each do |tenant|
        process_tenant(tenant, now: now)
      rescue StandardError => e
        Rails.logger.error("[alias_auto_confirm] tenant=#{tenant.id} failed: #{e.class}: #{e.message}")
      end
    end

    private

    def process_tenant(tenant, now:)
      auto_confirm_exact_tax_ids!(tenant) if auto_confirm_enabled?

      pending_count = VendorAlias.where(tenant_id: tenant.id, is_confirmed: false).count
      return if pending_count <= PENDING_THRESHOLD
      return if recently_emitted?(tenant, now: now)

      payload = build_payload(tenant: tenant, pending_count: pending_count, now: now)

      if hub.enabled?
        result = hub.send_event(payload)
        if result[:status] == :sent
          stamp_emitted!(tenant, at: now, hub_event_id: result[:hub_event_id])
          record_audit(tenant: tenant, pending_count: pending_count, hub_event_id: result[:hub_event_id])
        else
          Rails.logger.warn("[alias_auto_confirm] hub send returned #{result[:status]} for tenant=#{tenant.id}")
        end
      else
        Rails.logger.warn(
          "[alias_auto_confirm] tenant=#{tenant.id} pending=#{pending_count} — Hub disabled, no event emitted"
        )
      end
    end

    def auto_confirm_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("AUTO_CONFIRM_EXACT_TAXID", "true"))
    end

    def auto_confirm_exact_tax_ids!(tenant)
      VendorAlias
        .where(tenant_id: tenant.id, is_confirmed: false, confidence: 1.00)
        .update_all(is_confirmed: true, updated_at: Time.now.utc)
    end

    def recently_emitted?(tenant, now:)
      raw = (tenant.settings || {})["last_alias_review_emitted_at"]
      return false if raw.blank?
      last = Time.iso8601(raw.to_s).utc
      (now - last) < REEMIT_COOLDOWN
    rescue ArgumentError
      false
    end

    def build_payload(tenant:, pending_count:, now:)
      sample = VendorAlias
                 .where(tenant_id: tenant.id, is_confirmed: false)
                 .order(created_at: :desc)
                 .limit(SAMPLE_SIZE)
                 .pluck(:id, :source_system, :source_ref, :alias_text, :confidence, :vendor_id)
                 .map { |id, ss, sr, at, conf, vid|
                   { id: id, source_system: ss, source_ref: sr,
                     alias_text: at, confidence: conf.to_f, vendor_id: vid }
                 }

      {
        schema_version: SCHEMA_VERSION,
        event_type:     EVENT_TYPE,
        template_id:    HUB_TEMPLATE_ID,
        fired_at:       now.iso8601,
        tenant:         Tenants::CaptureSnapshot.call(tenant.id),
        pending_count:  pending_count,
        sample:         sample
      }
    end

    def stamp_emitted!(tenant, at:, hub_event_id:)
      next_settings = (tenant.settings || {}).merge(
        "last_alias_review_emitted_at" => at.iso8601,
        "last_alias_review_hub_event_id" => hub_event_id
      )
      tenant.update_columns(settings: next_settings, updated_at: at)
    end

    def record_audit(tenant:, pending_count:, hub_event_id:)
      Audit::Recorder.record(
        actor: "system:alias_auto_confirm",
        action: "ingestion.alias_review_emitted",
        entity_type: "Tenant",
        entity_id: tenant.id,
        tenant_id: tenant.id,
        after_state: { pending_count: pending_count, hub_event_id: hub_event_id }
      )
    rescue StandardError => e
      Rails.logger.error("[alias_auto_confirm] audit failed: #{e.class}: #{e.message}")
    end

    def hub
      Ecosystem::HubClient.instance || Ecosystem::HubClient.new
    end
  end
end
