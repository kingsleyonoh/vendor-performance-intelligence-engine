# frozen_string_literal: true

module Api
  module Vendors
    # POST /api/vendors/:id/merge — PRD §5.2, §8b. Collapses a duplicate
    # source vendor into a target. Both IDs must be under the caller's
    # tenant; cross-tenant refs → 404 via `tenant_scope.find`.
    #
    # Body: `{ into_vendor_id: "<uuid>" }`
    # Returns 200 `{ source:, target:, counts: { aliases_moved, signals_moved } }`.
    class MergeController < ::Api::BaseController
      def create
        source = tenant_scope.find(params[:id])
        into_id = extract_into_id

        unless into_id.present?
          return render_api_error(
            ::Errors::JsonApiError::VALIDATION_ERROR,
            message: "into_vendor_id is required.",
            details: [{ path: "into_vendor_id", issue: "required" }]
          )
        end

        if into_id == source.id
          return render_api_error(
            ::Errors::JsonApiError::VALIDATION_ERROR,
            message: "into_vendor_id must differ from :id.",
            details: [{ path: "into_vendor_id", issue: "same_as_source" }]
          )
        end

        if source.status == "merged"
          return render_api_error(
            ::Errors::JsonApiError::CONFLICT,
            message: "Source vendor is already merged."
          )
        end

        target = tenant_scope.find(into_id)
        authorize! source, to: :update?, with: VendorPolicy

        counts = ::Ingestion::VendorMerger.call(
          tenant: Current.tenant,
          source: source,
          target: target
        )

        source.reload
        target.reload

        ::Audit::Recorder.record(
          actor: Current.tenant,
          action: "vendors#merge",
          entity_type: "Vendor",
          entity_id: source.id,
          before_state: { status: "active" },
          after_state: { status: "merged", merge_into: target.id },
          tenant_id: Current.tenant.id
        )

        render json: {
          source: ::VendorSerializer.new(source).serializable_hash,
          target: ::VendorSerializer.new(target).serializable_hash,
          counts: counts
        }, status: :ok
      rescue ::Ingestion::VendorMerger::AlreadyMerged => e
        render_api_error(::Errors::JsonApiError::CONFLICT, message: e.message)
      rescue ::Ingestion::VendorMerger::SameVendor => e
        render_api_error(::Errors::JsonApiError::VALIDATION_ERROR, message: e.message)
      end

      private

      def tenant_scope
        Vendor.where(tenant_id: Current.tenant.id)
      end

      def extract_into_id
        body = request_body
        body[:into_vendor_id] || body["into_vendor_id"]
      end

      def request_body
        raw = request.request_parameters
        raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
        raw.deep_symbolize_keys
      rescue StandardError
        {}
      end
    end
  end
end
