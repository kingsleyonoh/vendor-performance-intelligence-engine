# frozen_string_literal: true

# UiBrand — PRD §4.T. Resolves brand colors for template rendering.
#
# When a tenant is session-scoped (Current.tenant set by Authentication
# concern), returns the tenant's configured `brand_primary_hex` /
# `brand_accent_hex`. When no tenant is set (the login screen, public
# pages), falls back to the PRD §4.T installation defaults.
#
# This helper is for LIVE rendering only — NOT for snapshot-frozen
# surfaces (alerts, PDFs). Those bind to a `TenantSnapshot` captured at
# emission time per §5.5 and §5.6.
module UiBrand
  # PRD §4.T installation defaults (used when no tenant session exists yet).
  DEFAULT_PRIMARY_HEX = "#0D0D0F"
  DEFAULT_ACCENT_HEX  = "#3B82F6"

  module_function

  def primary_for(tenant)
    tenant&.brand_primary_hex.presence || DEFAULT_PRIMARY_HEX
  end

  def accent_for(tenant)
    tenant&.brand_accent_hex.presence || DEFAULT_ACCENT_HEX
  end

  def display_name_for(tenant)
    tenant&.display_name.presence || "Vendor Performance Intelligence"
  end
end
