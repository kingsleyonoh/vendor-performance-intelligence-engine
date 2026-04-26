# frozen_string_literal: true

require "test_helper"

# POST /api/ingestion/sources/:id/pull-now — PRD §5, §8b. Operator-driven
# manual ingestion trigger. Creates a fresh ingestion_run with status=running
# and enqueues the appropriate per-source pull job.
module Api
  module Ingestion
    module Sources
      class PullNowControllerTest < ActionDispatch::IntegrationTest
        include ActiveJob::TestHelper

        ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
        GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

        setup do
          @acme = tenants(:acme_gmbh_de)
          @globex = tenants(:globex_inc_us)
          @source = create_source!(@acme, source_system: "webhook_engine", is_enabled: true)
          @prev_adapter = ActiveJob::Base.queue_adapter
          ActiveJob::Base.queue_adapter = :test
          queue_adapter.enqueued_jobs.clear
          queue_adapter.performed_jobs.clear
        end

        teardown do
          Current.tenant = nil
          ActiveJob::Base.queue_adapter = @prev_adapter if @prev_adapter
        end

        def acme_headers
          { "X-API-Key" => ACME_RAW_KEY, "Content-Type" => "application/json" }
        end

        def globex_headers
          { "X-API-Key" => GLOBEX_RAW_KEY, "Content-Type" => "application/json" }
        end

        def create_source!(tenant, source_system: "webhook_engine", is_enabled: true)
          IngestionSource.create!(
            tenant: tenant, source_system: source_system,
            is_enabled: is_enabled,
            connection_config: { "base_url" => "https://x.example",
                                 "api_key_ref" => "ENV:WEBHOOK_ENGINE_API_KEY" },
            pull_mode: "manual"
          )
        end

        test "POST /api/ingestion/sources/:id/pull-now enqueues job + creates run for webhook_engine" do
          assert_enqueued_with(job: ::Ingestion::WebhookEngineSignalPullJob) do
            post "/api/ingestion/sources/#{@source.id}/pull_now", headers: acme_headers
          end
          assert_equal 202, response.status, response.body
          body = JSON.parse(response.body)
          assert body.key?("ingestion_run_id"), "expected ingestion_run_id in body"
          assert_equal "queued", body["status"]

          run = IngestionRun.find(body["ingestion_run_id"])
          assert_equal "running", run.status
          assert_equal @acme.id, run.tenant_id
          assert_equal @source.id, run.ingestion_source_id
          assert_equal "manual", run.mode
        end

        test "POST pull-now on disabled source returns 409" do
          @source.update_columns(is_enabled: false)
          post "/api/ingestion/sources/#{@source.id}/pull_now", headers: acme_headers
          assert_equal 409, response.status, response.body
          body = JSON.parse(response.body)
          assert_equal "CONFLICT", body.dig("error", "code")
        end

        test "POST pull-now while another run is :running returns 409" do
          IngestionRun.create!(
            tenant: @acme, ingestion_source: @source,
            mode: "incremental", status: "running",
            started_at: 1.minute.ago
          )

          post "/api/ingestion/sources/#{@source.id}/pull_now", headers: acme_headers
          assert_equal 409, response.status
        end

        test "POST pull-now cross-tenant returns 404" do
          post "/api/ingestion/sources/#{@source.id}/pull_now", headers: globex_headers
          assert_equal 404, response.status
        end

        test "POST pull-now on unsupported source_system returns 422" do
          rag_src = create_source!(@acme, source_system: "rag_platform")
          post "/api/ingestion/sources/#{rag_src.id}/pull_now", headers: acme_headers
          assert_equal 422, response.status, response.body
          body = JSON.parse(response.body)
          assert_equal "ADAPTER_NOT_AVAILABLE", body.dig("error", "code")
          assert_match(/rag_platform|not yet implemented/i, body.dig("error", "message").to_s)
        end
      end
    end
  end
end
