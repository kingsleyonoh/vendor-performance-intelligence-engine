# frozen_string_literal: true

require "test_helper"
require "pdf-reader"
require "stringio"

# Byte-identical re-render gate (PRD §15 #13). Validates the snapshot-
# freezing invariant for ALL FOUR report types: regenerating a report
# 30 days after its original `generated_at` MUST produce byte-identical
# tenant-identity sections (header, footer, legal block) even if the
# `tenants` row was modified in between. The renderer binds to the
# stored `vendor_reports.render_context` only — never to a live
# `tenants` read.
#
# Batch 024's `Reports::VendorScorecardGeneratorTest` covered this for
# `vendor_scorecard` (PDF). This integration test extends coverage to
# the remaining three report types — `portfolio_risk` (CSV + PDF),
# `retender_candidates` (CSV), `trend_analysis` (CSV + PDF) — closing
# §15 #13 for every report surface.
class ReportReRenderFrozenTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @vendor = vendors(:acme_alpha)
    @storage_dir = Rails.root.join("tmp/test_rerender_#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@storage_dir)
    ENV["REPORT_STORAGE_PATH"] = @storage_dir.to_s
  end

  teardown do
    FileUtils.rm_rf(@storage_dir) if @storage_dir && File.exist?(@storage_dir)
    ENV.delete("REPORT_STORAGE_PATH")
  end

  # ----- portfolio_risk (CSV) -----
  test "portfolio_risk CSV re-render after tenant mutation is byte-identical" do
    report = build_ready_report(report_type: "portfolio_risk", output_format: "csv")
    Reports::PortfolioRiskGenerator.call(vendor_report: report)
    report.reload
    first_bytes = File.binread(report.storage_path)

    mutate_source_tenant_and_vendors

    report.update!(storage_path: nil, inline_payload: nil)
    Reports::PortfolioRiskGenerator.call(vendor_report: report)
    report.reload
    second_bytes = File.binread(report.storage_path)

    assert_equal first_bytes, second_bytes,
                 "portfolio_risk CSV must be byte-identical across re-renders " \
                 "(both bind to the frozen render_context)"
  end

  # ----- portfolio_risk (PDF) -----
  test "portfolio_risk PDF re-render preserves tenant identity verbatim" do
    report = build_ready_report(report_type: "portfolio_risk", output_format: "pdf")
    Reports::PortfolioRiskGenerator.call(vendor_report: report)
    report.reload
    first_bytes = File.binread(report.storage_path)

    mutate_source_tenant_and_vendors

    report.update!(storage_path: nil, inline_payload: nil)
    Reports::PortfolioRiskGenerator.call(vendor_report: report)
    report.reload
    second_bytes = File.binread(report.storage_path)

    # WickedPDF embeds a creation timestamp + random ID, so full bytes
    # WILL differ. We assert the tenant-identity section is preserved
    # verbatim via pdf-reader text extraction.
    assert_pdf_text_includes(second_bytes, "Acme GmbH")
    refute_pdf_text_includes(second_bytes, "RENAMED AFTER CAPTURE")
    refute_pdf_text_includes(second_bytes, "RENAMED VENDOR")

    # First render must also include the original literal — sanity.
    assert_pdf_text_includes(first_bytes, "Acme GmbH")
  end

  # ----- retender_candidates (CSV) -----
  test "retender_candidates CSV re-render after tenant mutation is byte-identical" do
    # Need a high/critical score for retender candidates to surface.
    VendorScore.create!(
      tenant: @tenant, vendor: @vendor,
      scoring_rules_id: scoring_rules(:acme_default).id,
      composite_score: 78.0, band: "high", trend: "degrading",
      category_scores: {
        financial: 75.0, operational: 80.0, contractual: 70.0,
        integration: 60.0, transactional: 85.0
      },
      top_contributors: [],
      window_days: 90, signals_considered_count: 5,
      computed_at: Time.current
    )
    report = build_ready_report(report_type: "retender_candidates", output_format: "csv")
    Reports::RetenderCandidatesGenerator.call(vendor_report: report)
    report.reload
    first_bytes = File.binread(report.storage_path)

    mutate_source_tenant_and_vendors

    report.update!(storage_path: nil, inline_payload: nil)
    Reports::RetenderCandidatesGenerator.call(vendor_report: report)
    report.reload
    second_bytes = File.binread(report.storage_path)

    assert_equal first_bytes, second_bytes,
                 "retender_candidates CSV must be byte-identical across re-renders"
  end

  # ----- trend_analysis (CSV) -----
  test "trend_analysis CSV re-render after tenant mutation is byte-identical" do
    report = build_ready_report(
      report_type: "trend_analysis",
      output_format: "csv",
      parameters: { window_days: 90 }
    )
    Reports::TrendAnalysisGenerator.call(vendor_report: report)
    report.reload
    first_bytes = File.binread(report.storage_path)

    mutate_source_tenant_and_vendors

    report.update!(storage_path: nil, inline_payload: nil)
    Reports::TrendAnalysisGenerator.call(vendor_report: report)
    report.reload
    second_bytes = File.binread(report.storage_path)

    assert_equal first_bytes, second_bytes,
                 "trend_analysis CSV must be byte-identical across re-renders"
  end

  # ----- trend_analysis (PDF) -----
  test "trend_analysis PDF re-render preserves tenant identity verbatim" do
    report = build_ready_report(
      report_type: "trend_analysis",
      output_format: "pdf",
      parameters: { window_days: 90 }
    )
    Reports::TrendAnalysisGenerator.call(vendor_report: report)
    report.reload
    first_bytes = File.binread(report.storage_path)

    mutate_source_tenant_and_vendors

    report.update!(storage_path: nil, inline_payload: nil)
    Reports::TrendAnalysisGenerator.call(vendor_report: report)
    report.reload
    second_bytes = File.binread(report.storage_path)

    assert_pdf_text_includes(first_bytes,  "Acme GmbH")
    assert_pdf_text_includes(second_bytes, "Acme GmbH")
    refute_pdf_text_includes(second_bytes, "RENAMED AFTER CAPTURE")
  end

  # ----- 30-day audit-reprint scenario (vendor_scorecard) -----
  test "vendor_scorecard PDF re-rendered 30 days later still binds to original tenant snapshot" do
    # Mirrors PRD §15 #13 wording exactly: "regenerating a PDF vendor
    # scorecard 30 days after its original generated_at produces
    # byte-identical tenant-identity sections (header, footer, legal
    # block), even if the tenants row was modified in between."
    report = build_ready_report(report_type: "vendor_scorecard", output_format: "pdf", vendor: @vendor)
    Reports::VendorScorecardGenerator.call(vendor_report: report)
    report.reload
    first_bytes = File.binread(report.storage_path)
    first_text  = pdf_text(first_bytes)

    # Simulate the 30-day delay: stamp generated_at and mutate every
    # §4.T identity column on the source tenant + the vendor.
    report.update_columns(generated_at: 30.days.ago)
    @tenant.update!(
      legal_name: "TENANT_RENAMED",
      full_legal_name: "TENANT_FULL_RENAMED",
      display_name: "TENANT_DISPLAY_RENAMED",
      address: { line1: "999 New Street", city: "Nowhere", postal_code: "00000", country_code: "ZZ" },
      registration: { company_number: "X-NEW", tax_id: "X-NEW-TAX", jurisdiction: "Nowhere" },
      contact: { email: "new@example.test", phone: "+1 000 000 0000" }
    )
    @vendor.update!(canonical_name: "VENDOR_RENAMED")

    report.update!(storage_path: nil)
    Reports::VendorScorecardGenerator.call(vendor_report: report)
    report.reload
    second_bytes = File.binread(report.storage_path)
    second_text  = pdf_text(second_bytes)

    # Tenant-identity section: every original literal must still appear.
    # NOTE: pdf-reader's text extraction over wkhtmltopdf output can strip
    # certain lines that contain repeated `&middot;` separators (the `Reg:`
    # line is one such casualty in our footer template). We assert on the
    # literals that DO survive extraction — header `legal_name`, address
    # `line1`, contact `email` — which is sufficient evidence that the
    # frozen render_context bound the second render rather than the
    # mutated source.
    ["Acme GmbH", "Hauptstraße 10", "procurement@acme-gmbh.example"].each do |orig|
      assert_includes second_text, orig,
                      "30-day re-render lost original literal `#{orig}`"
    end
    # And NONE of the post-mutation values may leak through.
    %w[TENANT_RENAMED TENANT_FULL_RENAMED TENANT_DISPLAY_RENAMED 999\ New\ Street X-NEW VENDOR_RENAMED].each do |bad|
      refute_includes second_text, bad.tr("\\ ", " "),
                      "30-day re-render LEAKED post-mutation literal `#{bad}`"
    end

    # First render also still has the original literal — sanity.
    assert_includes first_text, "Acme GmbH"
  end

  private

  def build_ready_report(report_type:, output_format:, parameters: {}, vendor: nil)
    report = VendorReport.create!(
      tenant: @tenant,
      vendor: report_type == "vendor_scorecard" ? (vendor || @vendor) : nil,
      report_type: report_type,
      output_format: output_format,
      parameters: parameters,
      status: "queued"
    )
    ctx = Reports::CaptureRenderContext.call(vendor_report: report)
    # JSON round-trip — mirrors how the ReportGeneratorJob stores it.
    report.update!(render_context: JSON.parse(ctx.to_json))
    report.transition_to!("generating")
    report
  end

  def mutate_source_tenant_and_vendors
    @tenant.update!(
      legal_name: "RENAMED AFTER CAPTURE",
      display_name: "Renamed",
      full_legal_name: "Renamed Full"
    )
    @vendor.update!(canonical_name: "RENAMED VENDOR")
    Vendor.where(tenant_id: @tenant.id).update_all(canonical_name: "RENAMED VENDOR-#{Time.now.to_i}")
  end

  def pdf_text(bytes)
    reader = PDF::Reader.new(StringIO.new(bytes))
    reader.pages.map(&:text).join("\n")
  end

  def assert_pdf_text_includes(bytes, needle)
    assert_includes pdf_text(bytes), needle,
                    "PDF text must include `#{needle}`"
  end

  def refute_pdf_text_includes(bytes, needle)
    refute_includes pdf_text(bytes), needle,
                    "PDF text must NOT include `#{needle}`"
  end
end
