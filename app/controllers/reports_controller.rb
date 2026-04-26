# frozen_string_literal: true

# ReportsController (UI) — PRD §5b, §8, §13.3.
#
# HTML/Turbo surface for operator-facing report generation + download.
# Sibling to `Api::ReportsController` (JSON for ecosystem consumers).
# Both scope queries on `Current.tenant.id` (set by Authentication concern).
#
# Cross-tenant: every read goes through `tenant_scope` so a sibling
# tenant's report id 404s.
class ReportsController < ApplicationController
  PER_PAGE = 25

  before_action :load_report, only: %i[show download]

  # GET /reports — list reports for Current.tenant.
  def index
    tenant_id = Current.tenant.id
    scope = VendorReport.where(tenant_id: tenant_id)
    scope = scope.where(status: params[:status]) if params[:status].present?
    @reports = scope.includes(:vendor).order(created_at: :desc).limit(PER_PAGE)
    @vendors = Vendor.where(tenant_id: tenant_id).order(:canonical_name).limit(500)
  end

  # POST /reports — operator-driven generation. Body keys mirror the API.
  def create
    report_type = params[:report_type].to_s
    output_format = params[:output_format].to_s
    vendor_id = params[:vendor_id].presence

    unless VendorReport::REPORT_TYPES.include?(report_type)
      redirect_to reports_path, alert: "Unknown report_type: #{report_type}" and return
    end
    unless VendorReport::OUTPUT_FORMATS.include?(output_format)
      redirect_to reports_path, alert: "Unknown output_format: #{output_format}" and return
    end
    if report_type == "vendor_scorecard" && vendor_id.blank?
      redirect_to reports_path, alert: "vendor_scorecard requires a vendor." and return
    end
    if report_type == "vendor_scorecard" && vendor_id.present?
      unless Vendor.exists?(id: vendor_id, tenant_id: Current.tenant.id)
        redirect_to reports_path, alert: "Vendor not found." and return
      end
    end

    parameters = {}
    parameters["vendor_id"] = vendor_id if vendor_id.present?
    parameters["window_days"] = params[:window_days].to_i if report_type == "trend_analysis" && params[:window_days].present?

    report = VendorReport.create!(
      tenant: Current.tenant,
      vendor_id: report_type == "vendor_scorecard" ? vendor_id : nil,
      report_type: report_type,
      output_format: output_format,
      parameters: parameters,
      status: "queued"
    )
    Reports::ReportGeneratorJob.perform_later(report.id)
    record_audit("reports#create", after: { id: report.id, report_type: report_type })

    redirect_to reports_path, notice: "Report queued."
  end

  # GET /reports/:id — operator detail (also useful for Turbo polling).
  def show
    @vendor = @report.vendor
  end

  # GET /reports/:id/download — stream the file (or inline_payload).
  def download
    unless @report.status == "ready"
      redirect_to reports_path, alert: "Report is not ready." and return
    end

    if @report.inline_payload.present?
      send_data @report.inline_payload,
                type: content_type_for(@report.output_format),
                filename: filename_for(@report),
                disposition: "attachment"
      return
    end

    if @report.storage_path.present? && File.exist?(@report.storage_path)
      send_file @report.storage_path,
                type: content_type_for(@report.output_format),
                filename: filename_for(@report),
                disposition: "attachment"
      return
    end

    redirect_to reports_path, alert: "Report file not available."
  end

  private

  def load_report
    @report = VendorReport.where(tenant_id: Current.tenant.id).find_by(id: params[:id])
    return if @report

    redirect_to reports_path, alert: "Report not found."
  end

  def content_type_for(output_format)
    case output_format
    when "pdf"  then "application/pdf"
    when "csv"  then "text/csv"
    when "json" then "application/json"
    else "application/octet-stream"
    end
  end

  def filename_for(report)
    "#{report.report_type}_#{report.id}.#{report.output_format}"
  end

  def record_audit(action, after: nil)
    Audit::Recorder.record(
      actor: Current.user || "tenant:#{Current.tenant.slug}",
      action: action,
      entity_type: "VendorReport",
      entity_id: nil,
      tenant_id: Current.tenant.id,
      after_state: after
    )
  rescue StandardError => e
    Rails.logger.error("ReportsController audit failed: #{e.class}: #{e.message}")
  end
end
