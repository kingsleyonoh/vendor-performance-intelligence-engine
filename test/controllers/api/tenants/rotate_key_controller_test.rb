# frozen_string_literal: true

require "test_helper"

# Tests for POST /api/tenants/me/rotate-key — PRD §8b.
# Covers atomic rotation (old key immediately invalid, new key works),
# raw-key-returned-once contract, cache invalidation on rotation, and audit
# hook firing.
module Api
  module Tenants
    class RotateKeyControllerTest < ActionDispatch::IntegrationTest
      ACME_RAW_KEY = "vpi_test_acme_key_00000000000000000000"

      setup do
        @previous_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
      end

      teardown do
        Current.tenant = nil
        Rails.cache = @previous_cache if @previous_cache
      end

      test "rotates key: old key no longer works, new key works" do
        # Kick off with the fixture key.
        post "/api/tenants/me/rotate-key", headers: { "X-API-Key" => ACME_RAW_KEY }

        assert_equal 200, response.status
        body = JSON.parse(response.body)
        new_key = body["api_key"]
        assert new_key.is_a?(String) && new_key.length >= 20

        # Old key now yields 401 on subsequent request.
        get "/api/tenants/me", headers: { "X-API-Key" => ACME_RAW_KEY }
        assert_equal 401, response.status,
          "old API key must be invalid immediately after rotation (got #{response.status})"

        # New key works.
        get "/api/tenants/me", headers: { "X-API-Key" => new_key }
        assert_equal 200, response.status
        body = JSON.parse(response.body)
        assert_equal tenants(:acme_gmbh_de).id, body.dig("tenant", "id")
      end

      test "rotate-key persists new hash, not the raw key" do
        post "/api/tenants/me/rotate-key", headers: { "X-API-Key" => ACME_RAW_KEY }
        assert_equal 200, response.status
        raw = JSON.parse(response.body)["api_key"]

        reloaded = tenants(:acme_gmbh_de).reload
        assert_equal Digest::SHA256.hexdigest(raw), reloaded.api_key_hash
        assert_equal raw[0, 12], reloaded.api_key_prefix
      end

      test "rotate-key writes an audit trail entry" do
        # Phase 3 (Batch 023): Audit::Recorder writes to audit_log_entries
        # by default. Earlier this test asserted on the [audit]-tagged log
        # line; it now asserts on the DB row.
        assert_difference -> { AuditLogEntry.where(action: "tenant.rotate_key").count }, 1 do
          post "/api/tenants/me/rotate-key", headers: { "X-API-Key" => ACME_RAW_KEY }
          assert_equal 200, response.status
        end
        row = AuditLogEntry.where(action: "tenant.rotate_key").order(occurred_at: :desc).first
        assert_equal "Tenant", row.actor_type
        assert_equal tenants(:acme_gmbh_de).id, row.tenant_id
      end

      test "rotate-key requires a valid API key" do
        post "/api/tenants/me/rotate-key"
        assert_equal 401, response.status
        assert_equal "UNAUTHORIZED", JSON.parse(response.body).dig("error", "code")
      end
    end
  end
end
