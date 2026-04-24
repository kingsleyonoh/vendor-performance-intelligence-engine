# frozen_string_literal: true

require "test_helper"

# Tests for /api/vendors/:id/signals — PRD §8b.
module Api
  module Vendors
    class SignalsControllerTest < ActionDispatch::IntegrationTest
      ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
      GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

      setup do
        @previous_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
        @acme = tenants(:acme_gmbh_de)
        @globex = tenants(:globex_inc_us)
        @vendor = Vendor.create!(
          tenant: @acme,
          canonical_name: "Signal Listing Vendor",
          status: "active"
        )
      end

      teardown do
        Current.tenant = nil
        Rails.cache = @previous_cache if @previous_cache
      end

      def acme_headers
        { "X-API-Key" => ACME_RAW_KEY, "Content-Type" => "application/json" }
      end

      def globex_headers
        { "X-API-Key" => GLOBEX_RAW_KEY, "Content-Type" => "application/json" }
      end

      def insert_signal(code: "invoice.late_ratio_30d", source: "invoice_recon",
                        value: 0.12, recorded_at: Time.now.utc, status: "normalized")
        VendorSignal.create!(
          tenant: @vendor.tenant,
          vendor: @vendor,
          signal_code: code,
          source_system: source,
          source_event_id: "list-#{SecureRandom.hex(4)}",
          value_numeric: value,
          recorded_at: recorded_at,
          status: status
        )
      end

      test "GET /api/vendors/:id/signals lists signals newest first" do
        old = insert_signal(recorded_at: 10.days.ago)
        mid = insert_signal(recorded_at: 3.days.ago)
        new = insert_signal(recorded_at: 1.hour.ago)

        get "/api/vendors/#{@vendor.id}/signals", headers: acme_headers
        assert_equal 200, response.status, response.body
        json = JSON.parse(response.body)
        ids = json["signals"].map { |s| s["id"] }
        assert_equal [new.id, mid.id, old.id], ids
        assert_equal 3, json.dig("pagination", "total_count")
      end

      test "GET /api/vendors/:id/signals filters by signal_code" do
        insert_signal(code: "invoice.late_ratio_30d")
        insert_signal(code: "invoice.dispute_rate_90d")

        get "/api/vendors/#{@vendor.id}/signals",
            params: { signal_code: "invoice.dispute_rate_90d" },
            headers: acme_headers
        assert_equal 200, response.status
        codes = JSON.parse(response.body)["signals"].map { |s| s["signal_code"] }
        assert_equal ["invoice.dispute_rate_90d"], codes
      end

      test "GET /api/vendors/:id/signals filters by source_system" do
        insert_signal(source: "invoice_recon")
        insert_signal(source: "contract_engine")
        get "/api/vendors/#{@vendor.id}/signals",
            params: { source_system: "contract_engine" },
            headers: acme_headers
        sources = JSON.parse(response.body)["signals"].map { |s| s["source_system"] }
        assert_equal ["contract_engine"], sources
      end

      test "GET /api/vendors/:id/signals with from/to uses partition pruning" do
        insert_signal(recorded_at: 60.days.ago)
        insert_signal(recorded_at: 2.days.ago)

        get "/api/vendors/#{@vendor.id}/signals",
            params: { from: 30.days.ago.iso8601, to: Time.now.utc.iso8601 },
            headers: acme_headers
        assert_equal 200, response.status
        json = JSON.parse(response.body)
        assert_equal 1, json["signals"].size
      end

      test "GET /api/vendors/:id/signals defaults to last 90 days when no from supplied" do
        insert_signal(recorded_at: 100.days.ago)
        insert_signal(recorded_at: 1.day.ago)

        get "/api/vendors/#{@vendor.id}/signals", headers: acme_headers
        assert_equal 200, response.status
        json = JSON.parse(response.body)
        # Only the 1-day-old row should be in the last-90-day window;
        # the 100-day-old row predates recorded_at >= now - 90d.
        assert_equal 1, json["signals"].size
      end

      test "GET /api/vendors/:id/signals cross-tenant returns 404" do
        insert_signal
        get "/api/vendors/#{@vendor.id}/signals", headers: globex_headers
        assert_equal 404, response.status
      end

      test "GET /api/vendors/:id/signals paginates" do
        6.times { |i| insert_signal(recorded_at: i.hours.ago) }
        get "/api/vendors/#{@vendor.id}/signals",
            params: { page: 2, per_page: 2 },
            headers: acme_headers
        assert_equal 200, response.status
        json = JSON.parse(response.body)
        assert_equal 2, json["signals"].size
        assert_equal 6, json.dig("pagination", "total_count")
        assert_equal 3, json.dig("pagination", "total_pages")
      end
    end
  end
end
