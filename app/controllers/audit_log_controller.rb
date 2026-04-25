# frozen_string_literal: true

# AuditLogController (UI) — PRD §5b, §8, §13.3.
#
# Read-only HTML/Turbo surface for the per-tenant audit trail. Distinct
# from `Api::AuditLogController` which serves JSON under `/api/audit-log`.
# Both surfaces scope queries to `Current.tenant.id`.
#
# Per Batch 007 design, v1 has no per-user role model — the gate is
# session authentication (handled by `ApplicationController`'s
# Authentication concern).
class AuditLogController < ApplicationController
  PER_PAGE = 50

  def index
    tenant_id = Current.tenant.id
    page = [params[:page].to_i, 1].max
    scope = AuditLogEntry.where(tenant_id: tenant_id).order(occurred_at: :desc)

    @total_count = scope.count
    @entries = scope.offset((page - 1) * PER_PAGE).limit(PER_PAGE)
    @page = page
    @per_page = PER_PAGE
  end
end
