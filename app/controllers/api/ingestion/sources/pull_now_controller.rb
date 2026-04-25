# frozen_string_literal: true

module Api
  module Ingestion
    module Sources
      # POST /api/ingestion/sources/:id/pull_now — PRD §5, §8b.
      #
      # Operator-driven manual pull trigger. Creates a fresh ingestion_run
      # (status='running', mode='manual') and enqueues the appropriate
      # per-source pull job. Returns 202 + ingestion_run_id.
      #
      # Pre-flight rejections:
      #   - source.is_enabled = false      → 409 CONFLICT
      #   - run with status='running' open → 409 CONFLICT
      #   - cross-tenant id                → 404 NOT_FOUND
      #   - unsupported source_system      → 422 ADAPTER_NOT_AVAILABLE
      class PullNowController < ::Api::BaseController
        # Maps source_system → Sidekiq job class. Phase 2 Batch 018 only
        # wires webhook_engine; later batches add invoice_recon, contract_engine,
        # recon_engine, rag_platform.
        ADAPTER_JOBS = {
          "webhook_engine" => "Ingestion::WebhookEngineSignalPullJob"
        }.freeze

        def create
          source = IngestionSource.where(tenant_id: Current.tenant.id).find(params[:id])
          authorize! source, to: :pull_now?, with: IngestionSourcePolicy

          unless source.is_enabled
            return render_api_error(
              ::Errors::JsonApiError::CONFLICT,
              message: "Cannot pull from disabled source. Enable it first."
            )
          end

          if IngestionRun.where(tenant_id: Current.tenant.id,
                                ingestion_source_id: source.id,
                                status: "running").exists?
            return render_api_error(
              ::Errors::JsonApiError::CONFLICT,
              message: "An ingestion run is already in progress for this source."
            )
          end

          job_class_name = ADAPTER_JOBS[source.source_system]
          if job_class_name.nil?
            return render_api_error(
              "ADAPTER_NOT_AVAILABLE",
              status: 422,
              message: "Pull job for source_system #{source.source_system.inspect} not yet implemented."
            )
          end

          run = IngestionRun.create!(
            tenant: Current.tenant,
            ingestion_source: source,
            mode: "manual",
            status: "running",
            started_at: Time.now.utc
          )

          job_class = job_class_name.constantize
          job_class.perform_later(source.id, run.id)

          render json: { ingestion_run_id: run.id, status: "queued" }, status: :accepted
        end
      end
    end
  end
end
