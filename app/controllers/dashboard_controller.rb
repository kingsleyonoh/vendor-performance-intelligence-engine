# frozen_string_literal: true

# DashboardController — PRD §5b, §8, §13.1.
#
# Primary operator entry point. Renders the "Daily vendor review" step-2
# KPI surface. All queries MUST scope by Current.tenant.id (invariant 1).
class DashboardController < ApplicationController
  # Authentication concern's before_action :require_authentication kicks in
  # automatically — no explicit declaration needed.

  def index
    tenant_id = Current.tenant.id
    @status_counts = Vendor.where(tenant_id: tenant_id).group(:status).count
    @band_counts   = Dashboard::BandCounter.call(tenant_id: tenant_id)
    @band_changes  = Dashboard::BandChangeTracker.call(tenant_id: tenant_id, since: 7.days.ago)
    @unacknowledged_alerts_count = 0  # Phase 2: risk_alerts pending → :acknowledged
  end
end
