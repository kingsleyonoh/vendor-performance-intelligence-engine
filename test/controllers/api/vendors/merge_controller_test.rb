# frozen_string_literal: true

require "test_helper"

# Tests for POST /api/vendors/:id/merge — PRD §5.2, §8b.
#
# Collapses a duplicate `source` vendor INTO a `target` vendor:
#   - All vendor_aliases reassigned from source → target.
#   - All vendor_signals reassigned from source → target (partition
#     integrity preserved — partition key is `recorded_at`, not vendor_id).
#   - Source vendor flipped to status='merged' with metadata.merge_into.
#   - In-flight alerts (Phase 2) are reassigned via an on_merge_hook.
#
# Tenant isolation: both vendors MUST belong to the caller's tenant; any
# cross-tenant reference → 404.
module Api
  module Vendors
    class MergeControllerTest < ActionDispatch::IntegrationTest
      ACME_RAW_KEY   = "vpi_test_acme_key_00000000000000000000"
      GLOBEX_RAW_KEY = "vpi_test_globex_key_00000000000000000"

      setup do
        @previous_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
        @acme = tenants(:acme_gmbh_de)
        @globex = tenants(:globex_inc_us)
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

      # --------------------------------------------------------------
      # Happy path
      # --------------------------------------------------------------

      test "merges aliases + signals from source → target and marks source merged" do
        source = Vendor.create!(tenant: @acme, canonical_name: "Duplicate Co")
        target = Vendor.create!(tenant: @acme, canonical_name: "Canonical Co")

        VendorAlias.create!(tenant: @acme, vendor: source,
                            source_system: "invoice_recon", source_ref: "inv-1",
                            confidence: 1.0, is_confirmed: true)
        VendorAlias.create!(tenant: @acme, vendor: source,
                            source_system: "webhook_engine", source_ref: "hook-1",
                            confidence: 0.85, is_confirmed: false)

        VendorSignal.create!(tenant: @acme, vendor: source,
                             signal_code: "invoice.late_ratio_30d",
                             source_system: "invoice_recon",
                             source_event_id: "evt-m-1",
                             value_numeric: 0.25,
                             recorded_at: 1.day.ago)
        VendorSignal.create!(tenant: @acme, vendor: source,
                             signal_code: "invoice.dispute_rate_90d",
                             source_system: "invoice_recon",
                             source_event_id: "evt-m-2",
                             value_numeric: 0.1,
                             recorded_at: 2.days.ago)
        VendorSignal.create!(tenant: @acme, vendor: source,
                             signal_code: "invoice.late_ratio_30d",
                             source_system: "invoice_recon",
                             source_event_id: "evt-m-3",
                             value_numeric: 0.4,
                             recorded_at: 3.days.ago)

        post "/api/vendors/#{source.id}/merge",
             params: { into_vendor_id: target.id }.to_json,
             headers: acme_headers

        assert_equal 200, response.status, response.body
        body = JSON.parse(response.body)
        assert_equal 2, body.dig("counts", "aliases_moved")
        assert_equal 3, body.dig("counts", "signals_moved")

        source.reload
        target.reload
        assert_equal "merged", source.status
        assert_equal target.id, source.metadata["merge_into"]
        assert source.metadata["merged_at"].present?

        # All aliases now point to target
        assert_equal 2, VendorAlias.where(vendor_id: target.id).count
        assert_equal 0, VendorAlias.where(vendor_id: source.id).count

        # All signals now point to target, with merged_at stamped
        assert_equal 3, VendorSignal.where(vendor_id: target.id).count
        assert_equal 0, VendorSignal.where(vendor_id: source.id).count
        moved_signals = VendorSignal.where(vendor_id: target.id)
        assert moved_signals.all? { |s| s.merged_at.present? }
      end

      # --------------------------------------------------------------
      # Validation
      # --------------------------------------------------------------

      test "rejects when into_vendor_id is missing" do
        source = Vendor.create!(tenant: @acme, canonical_name: "Alone")
        post "/api/vendors/#{source.id}/merge",
             params: {}.to_json,
             headers: acme_headers
        assert_equal 400, response.status
        body = JSON.parse(response.body)
        assert_equal "VALIDATION_ERROR", body.dig("error", "code")
      end

      test "rejects when into_vendor_id equals :id" do
        v = Vendor.create!(tenant: @acme, canonical_name: "Self")
        post "/api/vendors/#{v.id}/merge",
             params: { into_vendor_id: v.id }.to_json,
             headers: acme_headers
        assert_equal 400, response.status
      end

      test "rejects when source vendor is already merged → 409" do
        target = Vendor.create!(tenant: @acme, canonical_name: "Target")
        already = Vendor.create!(tenant: @acme, canonical_name: "Already", status: "merged")
        post "/api/vendors/#{already.id}/merge",
             params: { into_vendor_id: target.id }.to_json,
             headers: acme_headers
        assert_equal 409, response.status
      end

      # --------------------------------------------------------------
      # Tenant isolation
      # --------------------------------------------------------------

      test "cross-tenant target → 404" do
        acme_source = Vendor.create!(tenant: @acme, canonical_name: "Acme Src")
        globex_target = Vendor.create!(tenant: @globex, canonical_name: "Globex Tgt")

        post "/api/vendors/#{acme_source.id}/merge",
             params: { into_vendor_id: globex_target.id }.to_json,
             headers: acme_headers

        assert_equal 404, response.status
        acme_source.reload
        assert_equal "active", acme_source.status
      end

      test "cross-tenant source → 404" do
        acme_source = Vendor.create!(tenant: @acme, canonical_name: "Acme Src")
        globex_target = Vendor.create!(tenant: @globex, canonical_name: "Globex Tgt")

        post "/api/vendors/#{acme_source.id}/merge",
             params: { into_vendor_id: globex_target.id }.to_json,
             headers: globex_headers

        assert_equal 404, response.status
      end

      # --------------------------------------------------------------
      # Partition integrity — signals keep their recorded_at partitioning
      # --------------------------------------------------------------

      test "signal partitions unchanged after merge (partition key = recorded_at)" do
        source = Vendor.create!(tenant: @acme, canonical_name: "Old")
        target = Vendor.create!(tenant: @acme, canonical_name: "New")

        signal = VendorSignal.create!(
          tenant: @acme, vendor: source,
          signal_code: "invoice.late_ratio_30d",
          source_system: "invoice_recon",
          source_event_id: "evt-part-1",
          value_numeric: 0.5,
          recorded_at: 1.day.ago
        )

        # Record which partition the row lives in before
        pre_partition = ActiveRecord::Base.connection.select_value(<<~SQL)
          SELECT tableoid::regclass::text FROM vendor_signals WHERE id = '#{signal.id}'
        SQL

        post "/api/vendors/#{source.id}/merge",
             params: { into_vendor_id: target.id }.to_json,
             headers: acme_headers

        assert_equal 200, response.status, response.body

        post_partition = ActiveRecord::Base.connection.select_value(<<~SQL)
          SELECT tableoid::regclass::text FROM vendor_signals WHERE id = '#{signal.id}'
        SQL

        assert_equal pre_partition, post_partition,
                     "signal must remain in the same monthly partition after merge"
      end

      # --------------------------------------------------------------
      # on_merge hooks fire — Phase 2 wires alert re-parent here
      # --------------------------------------------------------------

      test "on_merge_hooks fire with source + target" do
        captured = []
        hook = ->(source:, target:) { captured << [source.id, target.id] }
        original = ::Ingestion::VendorMerger.on_merge_hooks.dup
        ::Ingestion::VendorMerger.on_merge_hooks << hook
        begin
          source = Vendor.create!(tenant: @acme, canonical_name: "Hook Src")
          target = Vendor.create!(tenant: @acme, canonical_name: "Hook Tgt")
          post "/api/vendors/#{source.id}/merge",
               params: { into_vendor_id: target.id }.to_json,
               headers: acme_headers
          assert_equal 200, response.status, response.body
          assert_equal [[source.id, target.id]], captured
        ensure
          ::Ingestion::VendorMerger.on_merge_hooks.replace(original)
        end
      end
    end
  end
end
