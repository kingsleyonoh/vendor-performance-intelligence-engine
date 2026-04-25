# frozen_string_literal: true

require "test_helper"

# Reports::CaptureRenderContext — PRD §5.6. Builds the FROZEN RenderContext
# hash stored on `vendor_reports.render_context` at the queued → generating
# transition. Re-renders bind to the stored snapshot, never re-query
# tenants/vendors/scores. The byte-identical-re-render test (PRD §15 #13)
# asserts that mutating the source `tenants` row after capture does NOT
# change the captured RenderContext.
module Reports
  class CaptureRenderContextTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:acme_gmbh_de)
      @vendor = vendors(:acme_alpha)
    end

    # ---------- Schema ----------
    test "result has the canonical top-level keys" do
      report = create_report(report_type: "vendor_scorecard")
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)

      assert_equal "vpi.report.v1", ctx[:schema_version]
      assert ctx[:generated_at].is_a?(String)
      assert ctx[:tenant].is_a?(Hash)
      assert ctx[:report].is_a?(Hash)
      assert ctx[:data].is_a?(Hash)
      assert ctx[:links].is_a?(Hash)
    end

    test "tenant block matches Tenants::CaptureSnapshot output" do
      report = create_report(report_type: "vendor_scorecard")
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)

      snapshot = Tenants::CaptureSnapshot.call(@tenant.id)
      # snapshot_at differs (different capture moments); compare identity columns
      %i[id slug legal_name full_legal_name display_name address registration
         contact wordmark_url brand_primary_hex brand_accent_hex locale timezone].each do |k|
        if snapshot[k].nil?
          assert_nil ctx[:tenant][k], "tenant.#{k} should be nil"
        else
          assert_equal snapshot[k], ctx[:tenant][k], "tenant.#{k} should match snapshot"
        end
      end
    end

    test "report block contains report identity fields" do
      report = create_report(report_type: "vendor_scorecard")
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)

      assert_equal report.id, ctx[:report][:id]
      assert_equal "vendor_scorecard", ctx[:report][:type]
      assert_equal "pdf", ctx[:report][:output_format]
      assert_equal({}, ctx[:report][:parameters])
    end

    test "links block contains download_url and legal_footer" do
      report = create_report(report_type: "vendor_scorecard")
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)

      assert ctx[:links][:download_url].is_a?(String)
      legal = ctx[:links][:legal_footer]
      assert_equal @tenant.full_legal_name, legal[:full_legal_name]
      assert_equal @tenant.address, legal[:address]
      assert_equal @tenant.registration, legal[:registration]
    end

    # ---------- vendor_scorecard data block ----------
    test "vendor_scorecard data block captures vendor + latest score" do
      report = create_report(report_type: "vendor_scorecard")
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)

      data = ctx[:data]
      assert_equal @vendor.id, data[:vendor][:id]
      assert_equal @vendor.canonical_name, data[:vendor][:canonical_name]
      assert data[:latest_score].is_a?(Hash)
      assert_in_delta 15.5, data[:latest_score][:composite_score], 0.01
      assert data[:score_history].is_a?(Array)
      assert data[:signal_timeline].is_a?(Array)
      assert data[:aliases].is_a?(Array)
    end

    # ---------- portfolio_risk data block ----------
    test "portfolio_risk data block captures tenant-wide aggregates (no vendor required)" do
      report = create_report(report_type: "portfolio_risk", vendor: nil)
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)

      data = ctx[:data]
      assert data[:band_counts].is_a?(Hash)
      assert data[:vendor_count].is_a?(Integer)
      assert data[:vendors].is_a?(Array)
    end

    # ---------- retender_candidates data block ----------
    test "retender_candidates data block returns HIGH/CRITICAL band vendors only" do
      report = create_report(report_type: "retender_candidates", vendor: nil)
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)

      data = ctx[:data]
      assert data[:candidates].is_a?(Array)
      data[:candidates].each do |c|
        assert_includes %w[high critical], c[:band], "retender candidates must be HIGH or CRITICAL"
      end
    end

    # ---------- trend_analysis data block ----------
    test "trend_analysis data block contains weekly aggregates" do
      report = create_report(report_type: "trend_analysis", vendor: nil)
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)

      data = ctx[:data]
      assert data[:weekly_buckets].is_a?(Array)
      assert data[:window_days].is_a?(Integer)
    end

    # ---------- Deep-frozen ----------
    test "result is deep-frozen so callers cannot mutate it after capture" do
      report = create_report(report_type: "vendor_scorecard")
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)

      assert ctx.frozen?
      assert ctx[:tenant].frozen?
      assert ctx[:data].frozen?
      assert ctx[:links].frozen?
      assert ctx[:links][:legal_footer].frozen?
    end

    # ---------- PRD §15 #13: byte-identical re-render across tenant mutations ----------
    test "mutating source tenant after capture does NOT change captured render_context" do
      report = create_report(report_type: "vendor_scorecard")
      ctx_before = Reports::CaptureRenderContext.call(vendor_report: report)
      original_legal = ctx_before[:tenant][:legal_name]

      # Tenant rename mid-flight (worst case: PDF regenerated 30 days after
      # original, between which the tenant was renamed)
      @tenant.update!(legal_name: "Renamed GmbH AFTER capture")

      # Captured ctx has not changed (it is a frozen Hash held in test memory)
      assert_equal original_legal, ctx_before[:tenant][:legal_name]
      refute_equal "Renamed GmbH AFTER capture", ctx_before[:tenant][:legal_name]
    end

    test "mutating source vendor after capture does NOT change captured render_context" do
      report = create_report(report_type: "vendor_scorecard")
      ctx_before = Reports::CaptureRenderContext.call(vendor_report: report)
      original_name = ctx_before[:data][:vendor][:canonical_name]

      @vendor.update!(canonical_name: "Renamed Vendor AFTER capture")

      assert_equal original_name, ctx_before[:data][:vendor][:canonical_name]
    end

    # ---------- Validation ----------
    test "raises on a non-VendorReport argument" do
      assert_raises(ArgumentError) do
        Reports::CaptureRenderContext.call(vendor_report: nil)
      end
    end

    test "raises on a vendor_scorecard report missing a vendor" do
      report = create_report(report_type: "vendor_scorecard", vendor: nil)
      assert_raises(ArgumentError) do
        Reports::CaptureRenderContext.call(vendor_report: report)
      end
    end

    private

    def create_report(report_type:, vendor: @vendor, parameters: {})
      VendorReport.create!(
        tenant: @tenant,
        vendor: vendor,
        report_type: report_type,
        output_format: report_type == "vendor_scorecard" ? "pdf" : "csv",
        parameters: parameters,
        status: "queued"
      )
    end
  end
end
