# frozen_string_literal: true

require "test_helper"
require "csv"

# Reports::TrendAnalysisGenerator — PRD §5, §13.3. Weekly aggregate
# CSV/PDF over the configured window_days. Bound to FROZEN render_context.
module Reports
  class TrendAnalysisGeneratorTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:acme_gmbh_de)
      @storage_dir = Rails.root.join("tmp/test_reports_#{SecureRandom.hex(4)}")
      FileUtils.mkdir_p(@storage_dir)
      ENV["REPORT_STORAGE_PATH"] = @storage_dir.to_s
    end

    teardown do
      FileUtils.rm_rf(@storage_dir) if @storage_dir && File.exist?(@storage_dir)
      ENV.delete("REPORT_STORAGE_PATH")
    end

    test "generates a CSV file with weekly aggregate columns" do
      report = build_report(output_format: "csv")
      ctx = report.render_context.deep_dup
      ctx["data"]["weekly_buckets"] = [
        { "week_start" => "2026-04-06", "score_count" => 4,
          "avg_composite" => 25.0,
          "band_counts" => { "low" => 2, "medium" => 1, "high" => 1, "critical" => 0 } },
        { "week_start" => "2026-04-13", "score_count" => 6,
          "avg_composite" => 30.0,
          "band_counts" => { "low" => 2, "medium" => 2, "high" => 1, "critical" => 1 } }
      ]
      report.update_columns(render_context: ctx)

      Reports::TrendAnalysisGenerator.call(vendor_report: report)
      report.reload

      rows = CSV.parse(File.read(report.storage_path), headers: true)
      %w[week_start total_vendors low medium high critical avg_composite_score].each do |h|
        assert_includes rows.headers, h
      end
      assert_equal 2, rows.size
      assert_equal "4", rows[0]["total_vendors"]
      assert_equal "2", rows[0]["low"]
      assert_equal "1", rows[1]["critical"]
    end

    test "generates a valid PDF when output_format is pdf" do
      report = build_report(output_format: "pdf")
      Reports::TrendAnalysisGenerator.call(vendor_report: report)
      report.reload

      bytes = File.binread(report.storage_path)
      assert bytes.start_with?("%PDF-")
    end

    test "single-week data emits one row" do
      report = build_report(output_format: "csv")
      ctx = report.render_context.deep_dup
      ctx["data"]["weekly_buckets"] = [
        { "week_start" => "2026-04-13", "score_count" => 3, "avg_composite" => 22.0,
          "band_counts" => { "low" => 3 } }
      ]
      report.update_columns(render_context: ctx)

      Reports::TrendAnalysisGenerator.call(vendor_report: report)
      report.reload
      rows = CSV.parse(File.read(report.storage_path), headers: true)
      assert_equal 1, rows.size
    end

    test "byte-identical CSV re-render after source mutation" do
      report = build_report(output_format: "csv")
      Reports::TrendAnalysisGenerator.call(vendor_report: report)
      report.reload
      first = File.binread(report.storage_path)

      @tenant.update!(legal_name: "MUTATED")
      report.update!(storage_path: nil)
      Reports::TrendAnalysisGenerator.call(vendor_report: report)
      report.reload
      second = File.binread(report.storage_path)

      assert_equal first, second
    end

    test "raises StrictFetchError on malformed render_context" do
      report = build_report(output_format: "csv")
      report.update_columns(render_context: { schema_version: "v1" })

      assert_raises(Reports::StrictFetchError) do
        Reports::TrendAnalysisGenerator.call(vendor_report: report)
      end
    end

    private

    def build_report(output_format:)
      report = VendorReport.create!(
        tenant: @tenant,
        vendor: nil,
        report_type: "trend_analysis",
        output_format: output_format,
        parameters: { window_days: 90 },
        status: "queued"
      )
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)
      report.update!(render_context: JSON.parse(ctx.to_json))
      report.transition_to!("generating")
      report
    end
  end
end
