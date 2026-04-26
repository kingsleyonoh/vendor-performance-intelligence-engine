# frozen_string_literal: true

require "test_helper"
require "csv"

# Reports::PortfolioRiskGenerator — PRD §5, §13.3. Tenant-wide vendor
# portfolio summary. CSV (default) or PDF output, both bound to the
# FROZEN render_context.
module Reports
  class PortfolioRiskGeneratorTest < ActiveSupport::TestCase
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

    test "generates a valid CSV file" do
      report = build_report(output_format: "csv")
      Reports::PortfolioRiskGenerator.call(vendor_report: report)
      report.reload

      assert File.exist?(report.storage_path)
      csv_text = File.read(report.storage_path)
      rows = CSV.parse(csv_text, headers: true)
      assert_equal %w[vendor_id canonical_name band composite_score], rows.headers & %w[vendor_id canonical_name band composite_score]
      # Acme has ≥3 vendors with current scores in fixtures
      assert rows.size >= 1, "should emit at least one vendor row"
      rows.each do |row|
        assert_includes %w[low medium high critical], row["band"]
      end
    end

    test "generates a valid PDF when output_format is pdf" do
      report = build_report(output_format: "pdf")
      Reports::PortfolioRiskGenerator.call(vendor_report: report)
      report.reload

      assert File.exist?(report.storage_path)
      bytes = File.binread(report.storage_path)
      assert bytes.start_with?("%PDF-")
      assert bytes.bytesize > 1_000
    end

    test "byte-identical CSV re-render after source tenant mutation" do
      report = build_report(output_format: "csv")
      Reports::PortfolioRiskGenerator.call(vendor_report: report)
      report.reload
      first_bytes = File.binread(report.storage_path)

      @tenant.update!(legal_name: "MUTATED")
      vendors(:acme_alpha).update!(canonical_name: "MUTATED VENDOR")

      report.update!(storage_path: nil)
      Reports::PortfolioRiskGenerator.call(vendor_report: report)
      report.reload
      second_bytes = File.binread(report.storage_path)

      assert_equal first_bytes, second_bytes,
                   "CSV re-render must be byte-identical (frozen render_context)"
    end

    test "writes 0-vendor CSV header when render_context has empty vendors array" do
      report = build_report(output_format: "csv")
      ctx = report.render_context.deep_dup
      ctx["data"]["vendors"] = []
      ctx["data"]["vendor_count"] = 0
      report.update_columns(render_context: ctx)

      Reports::PortfolioRiskGenerator.call(vendor_report: report)
      report.reload
      lines = File.read(report.storage_path).split("\n")
      assert_equal 1, lines.size, "should be header-only when no vendors"
      assert_match(/vendor_id/, lines[0])
    end

    test "raises StrictFetchError on malformed render_context" do
      report = build_report(output_format: "csv")
      report.update_columns(render_context: { schema_version: "v1" })

      assert_raises(Reports::StrictFetchError) do
        Reports::PortfolioRiskGenerator.call(vendor_report: report)
      end
    end

    private

    def build_report(output_format:)
      report = VendorReport.create!(
        tenant: @tenant,
        vendor: nil,
        report_type: "portfolio_risk",
        output_format: output_format,
        parameters: {},
        status: "queued"
      )
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)
      report.update!(render_context: JSON.parse(ctx.to_json))
      report.transition_to!("generating")
      report
    end
  end
end
