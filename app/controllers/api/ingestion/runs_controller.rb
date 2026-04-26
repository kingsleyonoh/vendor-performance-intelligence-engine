# frozen_string_literal: true

module Api
  module Ingestion
    # Read-only list of /api/ingestion/runs — PRD §5, §8b.
    #
    # Sorted by started_at DESC. Filterable by ingestion_source_id, status,
    # mode, from/to. Tenant-scoped via Current.tenant.
    class RunsController < ::Api::BaseController
      DEFAULT_PER_PAGE = 50
      MAX_PER_PAGE     = 200

      def index
        authorize! IngestionRun, with: IngestionRunPolicy
        scope = tenant_scope
        scope = scope.where(ingestion_source_id: params[:ingestion_source_id]) if params[:ingestion_source_id].present?
        scope = scope.where(status: params[:status]) if params[:status].present?
        scope = scope.where(mode: params[:mode]) if params[:mode].present?
        scope = scope.where("started_at >= ?", parse_time(params[:from])) if params[:from].present?
        scope = scope.where("started_at <= ?", parse_time(params[:to])) if params[:to].present?

        page, per_page = pagination_params
        total = scope.count
        paged = scope.order(started_at: :desc).offset((page - 1) * per_page).limit(per_page)

        render json: {
          ingestion_runs: IngestionRunSerializer.new(paged).serializable_hash,
          pagination: {
            page: page, per_page: per_page,
            total_count: total, total_pages: (total.to_f / per_page).ceil
          }
        }, status: :ok
      end

      def show
        authorize! IngestionRun, with: IngestionRunPolicy
        run = tenant_scope.find(params[:id])
        render json: { ingestion_run: IngestionRunSerializer.new(run).serializable_hash },
               status: :ok
      end

      private

      def tenant_scope
        IngestionRun.where(tenant_id: Current.tenant.id)
      end

      def parse_time(str)
        Time.iso8601(str.to_s).utc
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
end
