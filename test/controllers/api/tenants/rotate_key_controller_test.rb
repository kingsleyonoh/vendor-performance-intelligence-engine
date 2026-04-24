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
        log_io = StringIO.new
        logger = Logger.new(log_io)
        logger.formatter = ->(_severity, _time, _progname, msg) { "#{msg}\n" }
        previous_logger = Rails.logger
        Rails.logger = ActiveSupport::TaggedLogging.new(logger)

        begin
          post "/api/tenants/me/rotate-key", headers: { "X-API-Key" => ACME_RAW_KEY }
          assert_equal 200, response.status
          assert_match(/\[audit\]/, log_io.string,
                       "rotate-key must emit an [audit]-tagged log line")
          assert_match(/tenant.rotate_key/, log_io.string)
        ensure
          Rails.logger = previous_logger
        end
      end

      test "rotate-key requires a valid API key" do
        post "/api/tenants/me/rotate-key"
        assert_equal 401, response.status
        assert_equal "UNAUTHORIZED", JSON.parse(response.body).dig("error", "code")
      end
    end
  end
end
