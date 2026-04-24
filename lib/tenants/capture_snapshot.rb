# frozen_string_literal: true

module Tenants
  # Captures the PRD §4.T TenantSnapshot shape at a single point in time.
  # Consumed by:
  #
  # - `lib/alerts/capture_payload.rb` (Phase 2) — snapshots tenant identity
  #   into `risk_alerts.delivery_payload` at alert creation. The Hub
  #   dispatcher reads ONLY from delivery_payload, never re-queries
  #   tenants (PRD §5.5).
  # - `lib/reports/capture_render_context.rb` (Phase 3) — snapshots tenant
  #   identity into `vendor_reports.tenant_snapshot` / `.render_context`
  #   when ReportGeneratorJob transitions queued → generating. PDF
  #   re-downloads bind to this snapshot forever (PRD §5.6).
  # - Any future surface that needs template-bound tenant identity.
  #
  # The returned hash is frozen at the Ruby level to prevent accidental
  # mutation by callers. This is best-effort (deep freeze would require
  # JSON serializing which is overkill for this single-shape contract).
  class CaptureSnapshot
    # §4.T + PRD §4.1 columns that bind templates. Any addition here
    # requires a corresponding update to:
    #   - PRD §4.T table
    #   - `.agent/knowledge/foundation/tenant-snapshot-shape.md`
    #   - every template (PDF scorecard, Hub payload, email templates)
    #   - every fixture (test/fixtures/tenants.yml)
    IDENTITY_KEYS = %i[
      legal_name
      full_legal_name
      display_name
      address
      registration
      contact
      wordmark_url
      brand_primary_hex
      brand_accent_hex
      locale
      timezone
    ].freeze

    def self.call(tenant_id)
      new.call(tenant_id)
    end

    def call(tenant_id)
      tenant = Tenant.find(tenant_id)
      {
        id: tenant.id,
        slug: tenant.slug,
        legal_name: tenant.legal_name,
        full_legal_name: tenant.full_legal_name,
        display_name: tenant.display_name,
        address: tenant.address,
        registration: tenant.registration,
        contact: tenant.contact,
        wordmark_url: tenant.wordmark_url,
        brand_primary_hex: tenant.brand_primary_hex,
        brand_accent_hex: tenant.brand_accent_hex,
        locale: tenant.locale,
        timezone: tenant.timezone,
        snapshot_at: Time.now.utc.iso8601
      }.freeze
    end
  end
end
