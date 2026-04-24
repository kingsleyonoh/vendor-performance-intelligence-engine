# frozen_string_literal: true

# VendorsController (UI) — PRD §5b, §8, §13.1.
#
# Note the `Api::VendorsController` sibling under `app/controllers/api/`
# serves the JSON CRUD surface (PRD §8b). This controller powers the
# Hotwire HTML list page at `/vendors`. Both scope queries on
# `Current.tenant.id` — the invariant holds regardless of surface.
class VendorsController < ApplicationController
  PER_PAGE = 25

  def index
    tenant_id = Current.tenant.id
    @filters = filter_params
    @vendors, @latest_scores = Vendors::IndexQuery.call(tenant_id: tenant_id, filters: @filters, per_page: PER_PAGE)
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
