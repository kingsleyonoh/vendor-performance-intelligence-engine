# frozen_string_literal: true

# AlertsController (UI) — PRD §5b, §8, §13.2.
#
# HTML/Turbo surface for operator-facing alert triage. Sibling to
# `Api::AlertsController` (JSON for ecosystem consumers). Both scope
# queries on `Current.tenant.id` (set by Authentication concern).
#
# Cross-tenant: every read goes through `tenant_scope` so a sibling
# tenant's alert id 404s.
class AlertsController < ApplicationController
  PER_PAGE = 25

  before_action :load_alert, only: %i[show acknowledge suppress retry]

  # GET /alerts
  # Default view: pending + dispatching + delivered + failed (operationally
  # interesting) — explicitly exclude suppressed + resolved.
  def index
    tenant_id = Current.tenant.id

    @filters = {
      status:    params[:status].presence,
      band:      params[:band].presence,
      vendor_id: params[:vendor_id].presence
    }

    scope = RiskAlert.where(tenant_id: tenant_id)
    scope = if @filters[:status]
              scope.where(status: @filters[:status])
            else
              scope.where.not(status: %w[suppressed resolved])
            end
    scope = scope.where(new_band: @filters[:band]) if @filters[:band]
    scope = scope.where(vendor_id: @filters[:vendor_id]) if @filters[:vendor_id]

    @alerts = scope.includes(:vendor).order(created_at: :desc).limit(PER_PAGE)
  end

  # GET /alerts/:id
  def show
    @vendor = @alert.vendor
  end

  # POST /alerts/:id/acknowledge
  def acknowledge
    if @alert.acknowledged_at.present?
      redirect_to alerts_path, alert: "Alert is already acknowledged." and return
    end

    begin
      if @alert.status == "delivered"
        @alert.acknowledge!(by: actor_for_audit)
      else
        @alert.update!(
          status: "acknowledged",
          acknowledged_at: Time.now.utc,
          acknowledged_by: actor_for_audit
        )
      end
    rescue RiskAlert::InvalidStatusTransition => e
      redirect_to alerts_path, alert: e.message and return
    end

    record_audit("alerts#acknowledge", before: { status: "delivered" }, after: { status: @alert.status })

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace(dom_id_for(@alert), partial: "alerts/alert", locals: { alert: @alert }) }
      format.html { redirect_to alerts_path, notice: "Alert acknowledged." }
    end
  end

  # POST /alerts/:id/suppress
  def suppress
    until_param = params[:until].presence
    until_value = parse_time(until_param)

    if until_value.nil? || until_value <= Time.now.utc
      redirect_to alerts_path, alert: "Suppress 'until' must be a future timestamp." and return
    end

    @alert.update!(status: "suppressed", suppressed_until: until_value)
    record_audit("alerts#suppress", after: { status: "suppressed", suppressed_until: until_value })

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(dom_id_for(@alert)) }
      format.html { redirect_to alerts_path, notice: "Alert suppressed." }
    end
  end

  # POST /alerts/:id/retry
  def retry
    unless @alert.status == "failed"
      redirect_to alerts_path, alert: "Only failed alerts can be retried." and return
    end

    @alert.update!(status: "pending", last_error: nil)
    Alerts::HubDispatchJob.perform_later(@alert.id)
    record_audit("alerts#retry", after: { status: "pending" })

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace(dom_id_for(@alert), partial: "alerts/alert", locals: { alert: @alert }) }
      format.html { redirect_to alerts_path, notice: "Alert queued for retry." }
    end
  end

  private

  def load_alert
    @alert = RiskAlert.where(tenant_id: Current.tenant.id).find_by(id: params[:id])
    return if @alert

    redirect_to alerts_path, alert: "Alert not found."
  end

  def actor_for_audit
    Current.user ? "user:#{Current.user.email_address}" : "tenant:#{Current.tenant.slug}"
  end

  def parse_time(value)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def dom_id_for(alert)
    "alert_#{alert.id}"
  end

  def record_audit(action, before: nil, after: nil)
    Audit::Recorder.record(
      actor: Current.user || "tenant:#{Current.tenant.slug}",
      action: action,
      entity_type: "RiskAlert",
      entity_id: @alert.id,
      tenant_id: Current.tenant.id,
      before_state: before,
      after_state: after
    )
  rescue StandardError => e
    Rails.logger.error("AlertsController audit failed: #{e.class}: #{e.message}")
  end
end
