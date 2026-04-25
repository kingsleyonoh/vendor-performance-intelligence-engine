# frozen_string_literal: true

module Api
  # Reports JSON API — PRD §5, §8, §8b, §13.3.
  #
  # Endpoints (all tenant-scoped via Current.tenant):
  #   GET    /api/reports                — list with filters
  #   GET    /api/reports/:id            — single report
  #   POST   /api/reports                — enqueue generation, returns 202
  #   GET    /api/reports/:id/download   — stream the file (404 if not ready)
  #
  # Cross-tenant: every read goes through `tenant_scope` so a sibling
  # tenant's id 404s (never 403/200).
  class ReportsController < ::Api::BaseController
    DEFAULT_PER_PAGE = 25
    MAX_PER_PAGE     = 100

    before_action :load_report, only: %i[show download]

    # ---------------- INDEX ----------------
    def index
      authorize! VendorReport, with: VendorReportPolicy

      scope = tenant_scope
      scope = scope.where(report_type: params[:report_type]) if params[:report_type].present?
      scope = scope.where(status: params[:status])           if params[:status].present?
      scope = scope.where(vendor_id: params[:vendor_id])     if params[:vendor_id].present?
      scope = scope.where("created_at >= ?", parse_time(params[:from])) if params[:from].present?
      scope = scope.where("created_at <= ?", parse_time(params[:to]))   if params[:to].present?

      page, per_page = pagination_params
      total = scope.count
      paged = scope.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

      render json: {
        reports: paged.map { |r| serialize(r) },
        pagination: {
          page: page,
          per_page: per_page,
          total_count: total,
          total_pages: (total.to_f / per_page).ceil
        }
      }, status: :ok
    end

    # ---------------- SHOW ----------------
    def show
      authorize! @report, with: VendorReportPolicy
      render json: { report: serialize(@report, include_context: include_context?) }, status: :ok
    end

    # ---------------- CREATE ----------------
    def create
      authorize! VendorReport, with: VendorReportPolicy

      payload = parse_json_body
      result = ::Reports::RequestContract.new.call(payload)
      if result.failure?
        return render_validation_error_from_contract(result)
      end

      report_type = result[:report_type]
      output_format = result[:output_format]
      parameters_in = (result[:parameters] || {}).transform_keys(&:to_s)

      vendor_id = parameters_in["vendor_id"]
      if report_type == "vendor_scorecard" && vendor_id
        # Verify the vendor belongs to Current.tenant — silently 400 if not
        # (never expose existence of cross-tenant resources).
        unless Vendor.exists?(id: vendor_id, tenant_id: Current.tenant.id)
          return render_api_error(
            ::Errors::JsonApiError::VALIDATION_ERROR,
            status: :bad_request,
            message: "vendor_id not found in tenant",
            details: [{ path: "parameters.vendor_id", issue: "not found in tenant" }]
          )
        end
      end

      report = VendorReport.create!(
        tenant: Current.tenant,
        vendor_id: report_type == "vendor_scorecard" ? vendor_id : nil,
        report_type: report_type,
        output_format: output_format,
        parameters: parameters_in,
        status: "queued",
        requested_by_user_id: result[:requested_by_user_id]
      )

      ::Reports::ReportGeneratorJob.perform_later(report.id)

      render json: {
        report: serialize(report),
        status_url: "/api/reports/#{report.id}"
      }, status: :accepted
    end

    # ---------------- DOWNLOAD ----------------
    def download
      authorize! @report, with: VendorReportPolicy

      unless @report.status == "ready"
        return render_api_error(::Errors::JsonApiError::NOT_FOUND,
                                message: "Report is not ready.")
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

      render_api_error(::Errors::JsonApiError::NOT_FOUND,
                       message: "Report file not available.")
    end

    private

    def tenant_scope
      VendorReport.where(tenant_id: Current.tenant.id)
    end

    def load_report
      @report = tenant_scope.find(params[:id])
    end

    def include_context?
      v = params[:include_context]
      v.to_s.downcase == "true"
    end

    def serialize(report, include_context: false)
      hash = VendorReportSerializer.new(report).serializable_hash
      # Alba returns top-level :vendor_report key. Flatten if needed.
      payload = hash.is_a?(Hash) && hash[:vendor_report] ? hash[:vendor_report] : hash
      payload = payload.deep_stringify_keys if payload.respond_to?(:deep_stringify_keys)
      payload["render_context"] = report.render_context if include_context
      payload
    end

    def parse_json_body
      raw = request.raw_post
      return params.to_unsafe_h.deep_symbolize_keys if raw.blank?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed.deep_symbolize_keys : {}
    rescue JSON::ParserError
      {}
    end

    def render_validation_error_from_contract(result)
      details = result.errors.to_h.flat_map do |key, msgs|
        msgs_at_path(key, msgs)
      end
      render_api_error(
        ::Errors::JsonApiError::VALIDATION_ERROR,
        status: :bad_request,
        message: "Request payload is invalid.",
        details: details
      )
    end

    def msgs_at_path(key, messages, prefix = "")
      path = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
      case messages
      when Hash
        messages.flat_map { |sub_k, sub_v| msgs_at_path(sub_k, sub_v, path) }
      when Array
        messages.map { |m| { path: path, issue: m.to_s } }
      else
        [{ path: path, issue: messages.to_s }]
      end
    end

    def parse_time(value)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def pagination_params
      page = [params[:page].to_i, 1].max
      per_page = params[:per_page].present? ? params[:per_page].to_i : DEFAULT_PER_PAGE
      per_page = DEFAULT_PER_PAGE if per_page <= 0
      per_page = [per_page, MAX_PER_PAGE].min
      [page, per_page]
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
      ext = report.output_format
      "#{report.report_type}_#{report.id}.#{ext}"
    end
  end
end
