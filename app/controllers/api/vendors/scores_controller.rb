# frozen_string_literal: true

module Api
  module Vendors
    # Read endpoints under /api/vendors/:vendor_id/score — PRD §8b.
    #
    #   GET /api/vendors/:vendor_id/score/current  → latest vendor_scores row
    #   GET /api/vendors/:vendor_id/score/history  → paginated history
    #
    # Tenant isolation: the vendor lookup is scoped via Current.tenant; an
    # ID belonging to another tenant raises ActiveRecord::RecordNotFound
    # (rendered by BaseController as 404 — never 403, never 200 with empty).
    class ScoresController < ::Api::BaseController
      DEFAULT_PER_PAGE = 50
      MAX_PER_PAGE     = 200

      before_action :load_vendor

      def current
        authorize! @vendor, to: :show?, with: VendorPolicy
        score = VendorScore
                  .where(tenant_id: Current.tenant.id, vendor_id: @vendor.id)
                  .order(computed_at: :desc)
                  .first

        if score.nil?
          return render_api_error(
            ::Errors::JsonApiError::NOT_FOUND,
            message: "No scores computed for this vendor yet."
          )
        end

        render json: { score: ::VendorScoreSerializer.new(score).serializable_hash },
               status: :ok
      end

      def history
        authorize! @vendor, to: :show?, with: VendorPolicy

        scope = VendorScore
                  .where(tenant_id: Current.tenant.id, vendor_id: @vendor.id)
        scope = scope.where("computed_at >= ?", parse_time(params[:from])) if params[:from].present?
        scope = scope.where("computed_at <= ?", parse_time(params[:to]))   if params[:to].present?

        page, per_page = pagination_params
        total = scope.count
        paged = scope.order(computed_at: :desc).offset((page - 1) * per_page).limit(per_page)

        render json: {
          scores: ::VendorScoreSerializer.new(paged).serializable_hash,
          pagination: {
            page: page,
            per_page: per_page,
            total_count: total,
            total_pages: (total.to_f / per_page).ceil
          }
        }, status: :ok
      end

      private

      def load_vendor
        @vendor = Vendor
                    .where(tenant_id: Current.tenant.id)
                    .find(params[:vendor_id])
      end

      def pagination_params
        page = [params[:page].to_i, 1].max
        per_page = params[:per_page].present? ? params[:per_page].to_i : DEFAULT_PER_PAGE
        per_page = DEFAULT_PER_PAGE if per_page <= 0
        per_page = [per_page, MAX_PER_PAGE].min
        [page, per_page]
      end

      def parse_time(str)
        Time.iso8601(str.to_s).utc
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
