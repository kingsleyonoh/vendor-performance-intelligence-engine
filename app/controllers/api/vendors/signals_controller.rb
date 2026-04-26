# frozen_string_literal: true

module Api
  module Vendors
    # Read endpoint: GET /api/vendors/:vendor_id/signals — PRD §8b.
    #
    # Filters: signal_code, source_system, status, from, to.
    # Sort: recorded_at DESC. Paginated (default 50, max 200).
    #
    # Partition-pruning safety net: vendor_signals is partitioned by month
    # on recorded_at. If the caller supplies neither `from` nor `to`, we
    # cap the query at the last 90 days so the planner can prune partitions.
    class SignalsController < ::Api::BaseController
      DEFAULT_PER_PAGE       = 50
      MAX_PER_PAGE           = 200
      DEFAULT_WINDOW_DAYS    = 90

      before_action :load_vendor

      def index
        authorize! @vendor, to: :show?, with: VendorPolicy

        scope = VendorSignal
                  .where(tenant_id: Current.tenant.id, vendor_id: @vendor.id)
        scope = apply_filters(scope)

        from = parse_time(params[:from]) || (Time.now.utc - DEFAULT_WINDOW_DAYS.days)
        to   = parse_time(params[:to])

        scope = scope.where("recorded_at >= ?", from)
        scope = scope.where("recorded_at <= ?", to) if to

        page, per_page = pagination_params
        total = scope.count
        paged = scope.order(recorded_at: :desc).offset((page - 1) * per_page).limit(per_page)

        render json: {
          signals: ::VendorSignalSerializer.new(paged).serializable_hash,
          pagination: {
            page: page,
            per_page: per_page,
            total_count: total,
            total_pages: (total.to_f / per_page).ceil
          }
        }, status: :ok
      end

      private

      def apply_filters(scope)
        scope = scope.where(signal_code: params[:signal_code])   if params[:signal_code].present?
        scope = scope.where(source_system: params[:source_system]) if params[:source_system].present?
        scope = scope.where(status: params[:status])             if params[:status].present?
        scope
      end

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
        return nil if str.blank?

        Time.iso8601(str.to_s).utc
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
