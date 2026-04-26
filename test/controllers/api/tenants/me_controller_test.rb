# frozen_string_literal: true

require "test_helper"

# Tests for GET /api/tenants/me — PRD §8b.
# Depends on ApiKeyAuthenticator middleware to set Current.tenant. Assertions
# cover: valid key returns self, missing key → 401, cross-tenant isolation
# (response ID matches caller, never the other fixture), and that no hashed-
# key columns are exposed over the wire.
module Api
  module Tenants
    class MeControllerTest < ActionDispatch::IntegrationTest
      ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
      GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

      setup do
        @previous_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
      end

      teardown do
        Current.tenant = nil
        Rails.cache = @previous_cache if @previous_cache
      end

      test "with valid acme key returns acme tenant" do
        acme = tenants(:acme_gmbh_de)

        get "/api/tenants/me", headers: { "X-API-Key" => ACME_RAW_KEY }

        assert_equal 200, response.status
        body = JSON.parse(response.body)
        tenant = body["tenant"]

        assert_equal acme.id, tenant["id"]
        assert_equal "Acme", tenant["display_name"]
        assert_equal "acme-gmbh-de", tenant["slug"]
      end

      test "missing X-API-Key returns 401 UNAUTHORIZED" do
        get "/api/tenants/me"
        assert_equal 401, response.status
        assert_equal "UNAUTHORIZED", JSON.parse(response.body).dig("error", "code")
      end

      test "globex key returns globex, never acme (tenant isolation)" do
        globex = tenants(:globex_inc_us)

        get "/api/tenants/me", headers: { "X-API-Key" => GLOBEX_RAW_KEY }

        assert_equal 200, response.status
        body = JSON.parse(response.body)
        assert_equal globex.id, body.dig("tenant", "id")
        refute_equal tenants(:acme_gmbh_de).id, body.dig("tenant", "id")
        # Distinct-identity columns from the fixture — proves no leakage.
        assert_equal "Globex", body.dig("tenant", "display_name")
        assert_equal "en-US", body.dig("tenant", "locale")
      end

      test "response body excludes api_key_hash and api_key_prefix" do
        get "/api/tenants/me", headers: { "X-API-Key" => ACME_RAW_KEY }

        assert_equal 200, response.status
        # Case-insensitive scan for either field name.
        refute_match(/api_key_hash/i, response.body,
                     "api_key_hash must NEVER be serialized")
        refute_match(/api_key_prefix/i, response.body,
                     "api_key_prefix must NEVER be serialized")
      end
    end
  end
end
