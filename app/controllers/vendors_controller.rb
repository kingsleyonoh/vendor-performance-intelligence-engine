# frozen_string_literal: true

# VendorsController (UI) — PRD §5b, §8, §13.1.
#
# Note the `Api::VendorsController` sibling under `app/controllers/api/`
# serves the JSON CRUD surface (PRD §8b). This controller powers the
# Hotwire HTML list page at `/vendors`. Both scope queries on
# `Current.tenant.id` — the invariant holds regardless of surface.
class VendorsController < ApplicationController
  PER_PAGE = 25
  DETAIL_SIGNAL_LIMIT = 20
  DETAIL_HISTORY_DAYS = 90

  def index
    tenant_id = Current.tenant.id
    @filters = filter_params
    @vendors, @latest_scores = Vendors::IndexQuery.call(tenant_id: tenant_id, filters: @filters, per_page: PER_PAGE)
  end

  # GET /vendors/:id — PRD §5b primary journey steps 3-5.
  # Tenant-scoped: cross-tenant IDs raise RecordNotFound → rescue to redirect.
  def show
    tenant_id = Current.tenant.id
    @vendor = Vendor.where(tenant_id: tenant_id).find_by(id: params[:id])

    unless @vendor
      redirect_to vendors_path, alert: "Vendor not found." and return
    end

    @latest_score = VendorScore
      .where(tenant_id: tenant_id, vendor_id: @vendor.id)
      .order(computed_at: :desc)
      .first

    @score_history = VendorScore
      .where(tenant_id: tenant_id, vendor_id: @vendor.id)
      .where("computed_at >= ?", DETAIL_HISTORY_DAYS.days.ago)
      .order(computed_at: :asc)
      .pluck(:computed_at, :composite_score, :band)

    @recent_signals = VendorSignal
      .where(tenant_id: tenant_id, vendor_id: @vendor.id)
      .order(recorded_at: :desc)
      .limit(DETAIL_SIGNAL_LIMIT)
      .to_a

    @aliases = VendorAlias
      .where(tenant_id: tenant_id, vendor_id: @vendor.id)
      .order(is_confirmed: :asc, confidence: :desc, created_at: :desc)
      .to_a

    Analytics::Event.track(
      event: "vendor_viewed",
      tenant_id: tenant_id,
      user_id: Current.user&.id,
      properties: { vendor_id: @vendor.id }
    )
  end

  # POST /vendors/:id/terminate — soft-delete via status transition.
  # PRD §5.2 status lifecycle. Cross-tenant IDs → redirect with alert.
  def terminate
    tenant_id = Current.tenant.id
    vendor = Vendor.where(tenant_id: tenant_id).find_by(id: params[:id])

    unless vendor
      redirect_to vendors_path, alert: "Vendor not found." and return
    end

    if vendor.status == "terminated"
      redirect_to vendor_path(vendor), notice: "Vendor already terminated." and return
    end

    before = { status: vendor.status }
    vendor.update!(status: "terminated")

    ::Audit::Recorder.record(
      actor: Current.user,
      action: "vendors#terminate",
      entity_type: "Vendor",
      entity_id: vendor.id,
      tenant_id: tenant_id,
      before_state: before,
      after_state: { status: "terminated" }
    )

    redirect_to vendor_path(vendor), notice: "Vendor terminated."
  end

  # POST /vendors/bulk — bulk update category/status for selected vendors.
  # Tenant-scoped: only Current.tenant's vendors are eligible.
  def bulk
    tenant_id = Current.tenant.id
    ids = Array(params[:vendor_ids]).compact_blank

    attrs = {}
    attrs[:category] = params[:category].presence if params.key?(:category)
    attrs[:status]   = params[:status].presence if params.key?(:status) && Vendor::STATUSES.include?(params[:status])

    updated = 0
    if ids.any? && attrs.any?
      updated = Vendor.where(tenant_id: tenant_id, id: ids).update_all(attrs.merge(updated_at: Time.current))
    end

    redirect_to vendors_path, notice: "Updated #{updated} vendor(s)."
  end

  private

  def filter_params
    {
      band:     Array(params[:band]).compact_blank,
      category: Array(params[:category]).compact_blank,
      status:   Array(params[:status]).compact_blank,
      search:   params[:search].to_s.strip,
      min_spend: params[:min_spend].presence&.to_i,
      max_spend: params[:max_spend].presence&.to_i,
      sort:     params[:sort].presence,
      direction: params[:direction] == "asc" ? "asc" : "desc",
      page:     (params[:page].presence || 1).to_i
    }
  end
end
