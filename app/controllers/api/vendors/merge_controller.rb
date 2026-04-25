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

        validation_error = validate_merge_params(source, into_id)
        return validation_error if validation_error

        target = tenant_scope.find(into_id)
        authorize! source, to: :update?, with: VendorPolicy

        counts = perform_merge(source, target)
        source.reload
        target.reload

        record_merge_audit(source, target)
        render_merge_result(source, target, counts)
      rescue ::Ingestion::VendorMerger::AlreadyMerged => e
        render_api_error(::Errors::JsonApiError::CONFLICT, message: e.message)
      rescue ::Ingestion::VendorMerger::SameVendor => e
        render_api_error(::Errors::JsonApiError::VALIDATION_ERROR, message: e.message)
      end

      private

      def validate_merge_params(source, into_id)
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

        nil
      end

      def perform_merge(source, target)
        ::Ingestion::VendorMerger.call(
          tenant: Current.tenant,
          source: source,
          target: target
        )
      end

      def record_merge_audit(source, target)
        ::Audit::Recorder.record(
          actor: Current.tenant,
          action: "vendors#merge",
          entity_type: "Vendor",
          entity_id: source.id,
          before_state: { status: "active" },
          after_state: { status: "merged", merge_into: target.id },
          tenant_id: Current.tenant.id
        )
      end

      def render_merge_result(source, target, counts)
        render json: {
          source: ::VendorSerializer.new(source).serializable_hash,
          target: ::VendorSerializer.new(target).serializable_hash,
          counts: counts
        }, status: :ok
      end

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
