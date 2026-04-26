# frozen_string_literal: true

require "test_helper"

# /api/ingestion/runs — PRD §5, §8b. Read-only audit ledger of ingestion
# attempts. Sorted by started_at DESC.
module Api
  module Ingestion
    class RunsControllerTest < ActionDispatch::IntegrationTest
      ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
      GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

      setup do
        @acme = tenants(:acme_gmbh_de)
        @globex = tenants(:globex_inc_us)
        @acme_src = create_source!(@acme)
        @globex_src = create_source!(@globex, source_system: "invoice_recon")
      end

      teardown { Current.tenant = nil }

      def acme_headers
        { "X-API-Key" => ACME_RAW_KEY }
      end

      def globex_headers
        { "X-API-Key" => GLOBEX_RAW_KEY }
      end

      def create_source!(tenant, source_system: "webhook_engine")
        IngestionSource.create!(
          tenant: tenant, source_system: source_system,
          is_enabled: true,
          connection_config: { "base_url" => "https://x.example",
                               "api_key_ref" => "ENV:WEBHOOK_ENGINE_API_KEY" },
          pull_mode: "periodic"
        )
      end

      def create_run!(tenant, source, attrs = {})
        IngestionRun.create!(
          {
            tenant: tenant, ingestion_source: source,
            mode: "incremental", status: "succeeded",
            signals_attempted: 5, signals_stored: 4,
            signals_rejected: 1, signals_deduped: 0,
            started_at: 1.hour.ago, finished_at: 30.minutes.ago
          }.merge(attrs)
        )
      end

      test "GET /api/ingestion/runs lists only caller's runs sorted DESC by started_at" do
        older = create_run!(@acme, @acme_src, started_at: 2.hours.ago)
        newer = create_run!(@acme, @acme_src, started_at: 30.minutes.ago)
        create_run!(@globex, @globex_src) # cross-tenant

        get "/api/ingestion/runs", headers: acme_headers
        assert_equal 200, response.status
        body = JSON.parse(response.body)
        ids = body.fetch("ingestion_runs").map { |r| r["id"] }
        assert_equal [newer.id, older.id], ids, "expected DESC by started_at, only acme rows"
      end

      test "GET /api/ingestion/runs filters by ingestion_source_id" do
        other_src = create_source!(@acme, source_system: "invoice_recon")
        create_run!(@acme, @acme_src)
        target = create_run!(@acme, other_src)

        get "/api/ingestion/runs?ingestion_source_id=#{other_src.id}", headers: acme_headers
        assert_equal 200, response.status
        body = JSON.parse(response.body)
        ids = body["ingestion_runs"].map { |r| r["id"] }
        assert_equal [target.id], ids
      end

      test "GET /api/ingestion/runs filters by status" do
        create_run!(@acme, @acme_src, status: "succeeded")
        failed = create_run!(@acme, @acme_src, status: "failed")

        get "/api/ingestion/runs?status=failed", headers: acme_headers
        assert_equal 200, response.status
        body = JSON.parse(response.body)
        ids = body["ingestion_runs"].map { |r| r["id"] }
        assert_equal [failed.id], ids
      end

      test "GET /api/ingestion/runs/:id returns the run" do
        run = create_run!(@acme, @acme_src)
        get "/api/ingestion/runs/#{run.id}", headers: acme_headers
        assert_equal 200, response.status
        body = JSON.parse(response.body).fetch("ingestion_run")
        assert_equal run.id, body["id"]
      end

      test "GET /api/ingestion/runs/:id cross-tenant returns 404" do
        run = create_run!(@globex, @globex_src)
        get "/api/ingestion/runs/#{run.id}", headers: acme_headers
        assert_equal 404, response.status
      end

      test "missing X-API-Key returns 401" do
        get "/api/ingestion/runs"
        assert_equal 401, response.status
      end
    end
  end
end
