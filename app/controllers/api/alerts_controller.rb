# frozen_string_literal: true

module Api
  # CRUD-ish for /api/alerts — PRD §5, §8, §8b, §13.2.
  #
  # Endpoints (all tenant-scoped via Current.tenant):
  #   GET   /api/alerts                — list with filters (status/band/vendor_id/from/to)
  #   GET   /api/alerts/:id            — single alert + frozen delivery_payload
  #   POST  /api/alerts/:id/acknowledge — operator ack
  #   POST  /api/alerts/:id/suppress    — body: {until: ISO8601}; future timestamp required
  #   POST  /api/alerts/:id/retry       — only for status='failed'; resets to 'pending' + enqueues
  #
  # Cross-tenant: every read goes through `tenant_scope` so a sibling
  # tenant's id 404s (never 403/200).
  class AlertsController < ::Api::BaseController
    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE     = 200

    before_action :load_alert, only: %i[show acknowledge suppress retry]

    def index
      authorize! RiskAlert, with: RiskAlertPolicy

      scope = tenant_scope
      scope = scope.where(status: params[:status])           if params[:status].present?
      scope = scope.where(new_band: params[:band])           if params[:band].present?
      scope = scope.where(vendor_id: params[:vendor_id])     if params[:vendor_id].present?
      scope = scope.where("created_at >= ?", parse_time(params[:from])) if params[:from].present?
      scope = scope.where("created_at <= ?", parse_time(params[:to]))   if params[:to].present?

      page, per_page = pagination_params
      total = scope.count
      paged = scope.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

      render json: {
        alerts: RiskAlertSerializer.new(paged).serializable_hash,
        pagination: {
          page: page,
          per_page: per_page,
          total_count: total,
          total_pages: (total.to_f / per_page).ceil
        }
      }, status: :ok
    end

    def show
      authorize! @alert, with: RiskAlertPolicy
      render json: { alert: RiskAlertSerializer.new(@alert).serializable_hash }, status: :ok
    end

    def acknowledge
      authorize! @alert, with: RiskAlertPolicy

      if @alert.acknowledged_at.present?
        return render_api_error(::Errors::JsonApiError::CONFLICT,
                                message: "Alert is already acknowledged.")
      end

      # Allow ack from any non-terminal pre-ack state. Prefer routing through
      # the model's transition matrix where it permits, otherwise fall back
      # to setting columns directly with audit.
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
      rescue ::RiskAlert::InvalidStatusTransition => e
        return render_api_error(::Errors::JsonApiError::CONFLICT, message: e.message)
      end

      render json: { alert: RiskAlertSerializer.new(@alert).serializable_hash }, status: :ok
    end

    def suppress
      authorize! @alert, with: RiskAlertPolicy

      until_value = parse_time(suppress_until_param)
      if until_value.nil? || until_value <= Time.now.utc
        return render_api_error(
          ::Errors::JsonApiError::VALIDATION_ERROR,
          status: :bad_request,
          message: "`until` must be a future ISO8601 timestamp.",
          details: [{ path: "until", issue: "must be a future timestamp" }]
        )
      end

      begin
        @alert.update!(status: "suppressed", suppressed_until: until_value)
      rescue ::ActiveRecord::RecordInvalid => e
        return render_api_error(::Errors::JsonApiError::VALIDATION_ERROR,
                                message: e.message)
      end

      render json: { alert: RiskAlertSerializer.new(@alert).serializable_hash }, status: :ok
    end

    def retry
      authorize! @alert, with: RiskAlertPolicy

      unless @alert.status == "failed"
        return render_api_error(::Errors::JsonApiError::CONFLICT,
                                message: "Only failed alerts can be retried.")
      end

      # failed → pending is allowed by the model transition matrix.
      @alert.update!(status: "pending", last_error: nil)
      ::Alerts::HubDispatchJob.perform_later(@alert.id)

      render json: { alert: RiskAlertSerializer.new(@alert).serializable_hash }, status: :ok
    end

    private

    def tenant_scope
      RiskAlert.where(tenant_id: Current.tenant.id)
    end

    def load_alert
      @alert = tenant_scope.find(params[:id])
    end

    def actor_for_audit
      # API auth has no user id; use the tenant slug for traceability.
      "tenant:#{Current.tenant.slug}"
    end

    def suppress_until_param
      raw = request.request_parameters
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      raw["until"] || raw[:until] || params[:until]
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
  end
end
