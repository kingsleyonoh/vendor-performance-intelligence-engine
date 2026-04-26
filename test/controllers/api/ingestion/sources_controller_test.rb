# frozen_string_literal: true

require "test_helper"

# /api/ingestion/sources — PRD §5, §8b. CRUD on per-tenant ingestion source
# configurations. Connection-config secrets MUST be ENV references
# (e.g. "ENV:WEBHOOK_ENGINE_API_KEY"), never raw values — preventing
# accidental secret persistence at the schema layer.
module Api
  module Ingestion
    class SourcesControllerTest < ActionDispatch::IntegrationTest
      ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
      GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

      setup do
        @acme = tenants(:acme_gmbh_de)
        @globex = tenants(:globex_inc_us)
      end

      teardown { Current.tenant = nil }

      def acme_headers
        { "X-API-Key" => ACME_RAW_KEY, "Content-Type" => "application/json" }
      end

      def globex_headers
        { "X-API-Key" => GLOBEX_RAW_KEY, "Content-Type" => "application/json" }
      end

      def valid_payload(source_system: "webhook_engine")
        {
          source_system: source_system,
          is_enabled: true,
          connection_config: {
            base_url: "https://webhooks.example.com",
            api_key_ref: "ENV:WEBHOOK_ENGINE_API_KEY"
          },
          pull_mode: "periodic",
          pull_interval_minutes: 10
        }
      end

      def create_source!(tenant, attrs = {})
        IngestionSource.create!(
          {
            tenant: tenant,
            source_system: "webhook_engine",
            is_enabled: true,
            connection_config: { "base_url" => "https://x.example", "api_key_ref" => "ENV:WEBHOOK_ENGINE_API_KEY" },
            pull_mode: "periodic"
          }.merge(attrs)
        )
      end

      # ----------------------------------------------------------------
      # Index
      # ----------------------------------------------------------------
      test "GET /api/ingestion/sources lists only caller's sources" do
        create_source!(@acme)
        create_source!(@globex, source_system: "invoice_recon")

        get "/api/ingestion/sources", headers: acme_headers
        assert_equal 200, response.status, response.body
        body = JSON.parse(response.body)
        assert body.key?("ingestion_sources")
        assert_equal 1, body["ingestion_sources"].length
        assert_equal "webhook_engine", body["ingestion_sources"].first["source_system"]
      end

      test "GET /api/ingestion/sources filters by source_system" do
        create_source!(@acme, source_system: "webhook_engine")

        get "/api/ingestion/sources?source_system=webhook_engine", headers: acme_headers
        assert_equal 200, response.status
        body = JSON.parse(response.body)
        assert_equal 1, body["ingestion_sources"].length
      end

      test "GET /api/ingestion/sources filters by is_enabled" do
        create_source!(@acme, source_system: "webhook_engine", is_enabled: true)
        create_source!(@acme, source_system: "invoice_recon", is_enabled: false)

        get "/api/ingestion/sources?is_enabled=false", headers: acme_headers
        assert_equal 200, response.status
        body = JSON.parse(response.body)
        codes = body["ingestion_sources"].map { |s| s["source_system"] }
        assert_includes codes, "invoice_recon"
        refute_includes codes, "webhook_engine"
      end

      # ----------------------------------------------------------------
      # Show
      # ----------------------------------------------------------------
      test "GET /api/ingestion/sources/:id returns the source" do
        src = create_source!(@acme)
        get "/api/ingestion/sources/#{src.id}", headers: acme_headers
        assert_equal 200, response.status
        body = JSON.parse(response.body).fetch("ingestion_source")
        assert_equal src.id, body["id"]
      end

      test "GET /api/ingestion/sources/:id cross-tenant returns 404" do
        src = create_source!(@acme)
        get "/api/ingestion/sources/#{src.id}", headers: globex_headers
        assert_equal 404, response.status
      end

      test "GET /api/ingestion/sources sanitizes connection_config secrets in response" do
        create_source!(@acme,
                       connection_config: { "base_url" => "https://x.example",
                                            "api_key_ref" => "ENV:WEBHOOK_ENGINE_API_KEY" })

        get "/api/ingestion/sources", headers: acme_headers
        body = JSON.parse(response.body)
        cfg = body["ingestion_sources"].first["connection_config"]
        # api_key_ref MUST be replaced with placeholder.
        assert_equal "<configured>", cfg["api_key_ref"]
        # Non-secret fields preserved.
        assert_equal "https://x.example", cfg["base_url"]
      end

      # ----------------------------------------------------------------
      # Create
      # ----------------------------------------------------------------
      test "POST /api/ingestion/sources creates source" do
        post "/api/ingestion/sources", params: valid_payload.to_json, headers: acme_headers
        assert_equal 201, response.status, response.body
        body = JSON.parse(response.body).fetch("ingestion_source")
        assert_equal "webhook_engine", body["source_system"]
      end

      test "POST /api/ingestion/sources rejects raw secret in connection_config" do
        bad = valid_payload.merge(
          connection_config: { base_url: "https://x.example", api_key: "raw-secret-leaked" }
        )
        post "/api/ingestion/sources", params: bad.to_json, headers: acme_headers
        assert_equal 400, response.status
        body = JSON.parse(response.body)
        assert_equal "VALIDATION_ERROR", body.dig("error", "code")
        # Detail must mention secret-ref policy.
        joined = (body.dig("error", "details") || []).map { |d| d["issue"] }.join(" ")
        assert_match(/secret|api_key_ref|ENV:/i, joined)
      end

      test "POST /api/ingestion/sources rejects raw secret as api_key_ref value" do
        bad = valid_payload.merge(
          connection_config: { base_url: "https://x.example", api_key_ref: "raw-not-an-env-ref" }
        )
        post "/api/ingestion/sources", params: bad.to_json, headers: acme_headers
        assert_equal 400, response.status
      end

      test "POST /api/ingestion/sources rejects unknown source_system" do
        bad = valid_payload.merge(source_system: "garbage")
        post "/api/ingestion/sources", params: bad.to_json, headers: acme_headers
        assert_equal 400, response.status
      end

      test "POST /api/ingestion/sources rejects duplicate source_system per tenant" do
        create_source!(@acme, source_system: "webhook_engine")
        post "/api/ingestion/sources", params: valid_payload.to_json, headers: acme_headers
        assert_includes [409, 422, 400], response.status, "expected conflict on dup; got #{response.status}: #{response.body}"
      end

      # ----------------------------------------------------------------
      # Update
      # ----------------------------------------------------------------
      test "PATCH /api/ingestion/sources/:id partial update is_enabled" do
        src = create_source!(@acme, is_enabled: true)
        patch "/api/ingestion/sources/#{src.id}",
              params: { is_enabled: false }.to_json, headers: acme_headers
        assert_equal 200, response.status
        assert_equal false, JSON.parse(response.body).dig("ingestion_source", "is_enabled")
      end

      test "PATCH cross-tenant returns 404" do
        src = create_source!(@acme)
        patch "/api/ingestion/sources/#{src.id}",
              params: { is_enabled: false }.to_json, headers: globex_headers
        assert_equal 404, response.status
      end

      # ----------------------------------------------------------------
      # Destroy (soft-delete)
      # ----------------------------------------------------------------
      test "DELETE /api/ingestion/sources/:id soft-deletes by setting is_enabled=false" do
        src = create_source!(@acme, is_enabled: true)
        delete "/api/ingestion/sources/#{src.id}", headers: acme_headers
        assert_equal 200, response.status
        # Row still exists.
        assert IngestionSource.exists?(src.id)
        assert_equal false, src.reload.is_enabled
      end

      test "DELETE cross-tenant returns 404" do
        src = create_source!(@acme)
        delete "/api/ingestion/sources/#{src.id}", headers: globex_headers
        assert_equal 404, response.status
        assert IngestionSource.exists?(src.id)
      end

      # ----------------------------------------------------------------
      # Auth
      # ----------------------------------------------------------------
      test "missing X-API-Key returns 401" do
        get "/api/ingestion/sources"
        assert_equal 401, response.status
      end
    end
  end
end
