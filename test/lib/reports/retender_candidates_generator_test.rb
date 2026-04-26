# frozen_string_literal: true

require "test_helper"
require "csv"

# Reports::RetenderCandidatesGenerator — PRD §5, §13.3. CSV-only listing
# of HIGH and CRITICAL band vendors with a recommended action derived
# from composite_score. Bound to FROZEN render_context — no live queries.
module Reports
  class RetenderCandidatesGeneratorTest < ActiveSupport::TestCase
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

    test "generates a CSV file with high/critical candidates only" do
      report = build_report
      Reports::RetenderCandidatesGenerator.call(vendor_report: report)
      report.reload

      assert File.exist?(report.storage_path)
      csv_text = File.read(report.storage_path)
      rows = CSV.parse(csv_text, headers: true)
      expected_headers = %w[vendor_id canonical_name band composite_score recommended_action]
      expected_headers.each do |h|
        assert_includes rows.headers, h, "missing header #{h}"
      end
      rows.each do |row|
        assert_includes %w[high critical], row["band"]
        assert_includes [
          "RFQ immediately",
          "Monitor 30d then RFQ",
          "Watchlist"
        ], row["recommended_action"]
      end
    end

    test "stores small payload inline as well as on disk" do
      report = build_report
      Reports::RetenderCandidatesGenerator.call(vendor_report: report)
      report.reload

      assert report.inline_payload.present?,
             "small CSV should be kept inline_payload for fast download"
      assert_equal File.read(report.storage_path), report.inline_payload
    end

    test "empty candidates list emits a header-only CSV" do
      report = build_report
      ctx = report.render_context.deep_dup
      ctx["data"]["candidates"] = []
      report.update_columns(render_context: ctx)

      Reports::RetenderCandidatesGenerator.call(vendor_report: report)
      report.reload
      lines = File.read(report.storage_path).split("\n")
      assert_equal 1, lines.size
    end

    test "byte-identical re-render after source mutation" do
      report = build_report
      Reports::RetenderCandidatesGenerator.call(vendor_report: report)
      report.reload
      first = File.binread(report.storage_path)

      vendors(:acme_gamma).update!(canonical_name: "MUTATED")
      report.update!(storage_path: nil, inline_payload: nil)
      Reports::RetenderCandidatesGenerator.call(vendor_report: report)
      report.reload
      second = File.binread(report.storage_path)

      assert_equal first, second
    end

    test "recommended_action thresholds: <30=RFQ immediately, 30-49=Monitor 30d, 50+=Watchlist" do
      report = build_report
      ctx = report.render_context.deep_dup
      ctx["data"]["candidates"] = [
        { "vendor_id" => "v1", "canonical_name" => "A", "band" => "critical",
          "composite_score" => 25.0, "top_contributors" => [] },
        { "vendor_id" => "v2", "canonical_name" => "B", "band" => "critical",
          "composite_score" => 40.0, "top_contributors" => [] },
        { "vendor_id" => "v3", "canonical_name" => "C", "band" => "high",
          "composite_score" => 65.0, "top_contributors" => [] }
      ]
      report.update_columns(render_context: ctx)

      Reports::RetenderCandidatesGenerator.call(vendor_report: report)
      report.reload
      rows = CSV.parse(File.read(report.storage_path), headers: true)
      by_id = rows.each_with_object({}) { |r, h| h[r["vendor_id"]] = r["recommended_action"] }
      assert_equal "RFQ immediately",      by_id["v1"]
      assert_equal "Monitor 30d then RFQ", by_id["v2"]
      assert_equal "Watchlist",            by_id["v3"]
    end

    private

    def build_report
      report = VendorReport.create!(
        tenant: @tenant,
        vendor: nil,
        report_type: "retender_candidates",
        output_format: "csv",
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
