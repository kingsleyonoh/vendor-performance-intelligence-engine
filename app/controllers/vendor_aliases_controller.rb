# frozen_string_literal: true

# VendorAliasesController (UI) — PRD §8, §13.3.
#
# Operator-facing pending-confirm queue. HTML/Turbo surface mirroring
# `Api::VendorAliasesController#pending` (JSON). Confirm + Reject hit
# the same model rows, scoped on `Current.tenant.id` set by the
# Authentication concern.
#
# Confirm: flips `is_confirmed=true` (audit-logged).
# Reject:  deletes the alias row outright (audit-logged).
class VendorAliasesController < ApplicationController
  before_action :load_alias, only: %i[confirm reject]

  # GET /aliases/pending
  def pending
    @aliases = VendorAlias
      .where(tenant_id: Current.tenant.id, is_confirmed: false)
      .includes(:vendor)
      .order(:confidence, created_at: :desc)
  end

  # POST /aliases/:id/confirm
  def confirm
    @alias.update!(is_confirmed: true)
    record_audit("vendor_alias.confirm", entity_id: @alias.id,
                 after: { is_confirmed: true })
    redirect_to pending_vendor_aliases_path, notice: "Alias confirmed."
  end

  # POST /aliases/:id/reject
  def reject
    target_id = @alias.id
    @alias.destroy!
    record_audit("vendor_alias.reject", entity_id: target_id,
                 after: { deleted: true })
    redirect_to pending_vendor_aliases_path, notice: "Alias rejected."
  end

  private

  def load_alias
    @alias = VendorAlias.where(tenant_id: Current.tenant.id).find_by(id: params[:id])
    return if @alias

    redirect_to pending_vendor_aliases_path, alert: "Alias not found."
  end

  def record_audit(action, entity_id:, after: nil)
    Audit::Recorder.record(
      actor: Current.user || "tenant:#{Current.tenant.slug}",
      action: action,
      entity_type: "VendorAlias",
      entity_id: entity_id,
      tenant_id: Current.tenant.id,
      after_state: after
    )
  rescue StandardError => e
    Rails.logger.error("VendorAliasesController audit failed: #{e.class}: #{e.message}")
  end
end
