# frozen_string_literal: true

require "test_helper"

# Api::ReportsController — PRD §5, §8, §8b, §13.3.
#
# Endpoints (all tenant-scoped via Current.tenant from X-API-Key middleware):
#
#   GET    /api/reports                — list with filters (report_type/status/vendor_id/from/to)
#   GET    /api/reports/:id            — single report (excluding heavy render_context by default)
#   POST   /api/reports                — create + enqueue Reports::ReportGeneratorJob (returns 202)
#   GET    /api/reports/:id/download   — streams the file (404 if not ready)
#
# Tenant isolation: every read goes through `tenant_scope` so a sibling
# tenant's id 404s (never 403/200).
class Api::ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @other_tenant = tenants(:globex_inc_us)
    @vendor = vendors(:acme_alpha)
    @other_vendor = vendors(:globex_eta)

    @api_key = "vpi_test_acme_key_00000000000000000000"
    @other_api_key = "vpi_test_globex_key_00000000000000000"

    @storage_dir = Rails.root.join("tmp/test_reports_api_#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@storage_dir)
    ENV["REPORT_STORAGE_PATH"] = @storage_dir.to_s
  end

  teardown do
    FileUtils.rm_rf(@storage_dir) if @storage_dir && File.exist?(@storage_dir)
    ENV.delete("REPORT_STORAGE_PATH")
  end

  # ---------------- INDEX ----------------

  test "GET /api/reports returns paginated list scoped to tenant" do
    create_report(tenant: @tenant, report_type: "portfolio_risk", status: "ready")
    create_report(tenant: @tenant, report_type: "vendor_scorecard", status: "queued")
    create_report(tenant: @other_tenant, report_type: "portfolio_risk", status: "ready")

    get "/api/reports", headers: auth_header(@api_key)
    assert_response :success
    body = JSON.parse(response.body)
    assert body["reports"].present? || body["data"].present?
    rows = body["reports"] || body["data"] || []
    assert_equal 2, rows.size
    body["pagination"].tap do |p|
      assert_equal 2, p["total_count"]
      assert_equal 1, p["page"]
    end
  end

  test "GET /api/reports filters by report_type" do
    create_report(tenant: @tenant, report_type: "portfolio_risk", status: "ready")
    create_report(tenant: @tenant, report_type: "vendor_scorecard", status: "ready")

    get "/api/reports", params: { report_type: "vendor_scorecard" }, headers: auth_header(@api_key)
    assert_response :success
    rows = JSON.parse(response.body).fetch("reports", []) | []
    assert_equal 1, rows.size
    assert_equal "vendor_scorecard", rows.first["report_type"]
  end

  test "GET /api/reports filters by status" do
    create_report(tenant: @tenant, report_type: "portfolio_risk", status: "ready")
    create_report(tenant: @tenant, report_type: "portfolio_risk", status: "queued")

    get "/api/reports", params: { status: "queued" }, headers: auth_header(@api_key)
    assert_response :success
    rows = JSON.parse(response.body).fetch("reports", [])
    assert_equal 1, rows.size
    assert_equal "queued", rows.first["status"]
  end

  test "GET /api/reports without API key → 401" do
    get "/api/reports"
    assert_response :unauthorized
  end

  # ---------------- SHOW ----------------

  test "GET /api/reports/:id returns single report" do
    report = create_report(tenant: @tenant, report_type: "portfolio_risk", status: "ready")

    get "/api/reports/#{report.id}", headers: auth_header(@api_key)
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal report.id, body["report"]["id"]
  end

  test "GET /api/reports/:id cross-tenant returns 404 (not 403)" do
    report = create_report(tenant: @other_tenant, report_type: "portfolio_risk", status: "ready")

    get "/api/reports/#{report.id}", headers: auth_header(@api_key)
    assert_response :not_found
  end

  test "GET /api/reports/:id excludes render_context by default; include_context=true exposes it" do
    report = create_report(tenant: @tenant, report_type: "portfolio_risk", status: "ready")
    report.update_columns(render_context: { schema_version: "vpi.report.v1", tenant: { legal_name: "Acme GmbH" } })

    get "/api/reports/#{report.id}", headers: auth_header(@api_key)
    body = JSON.parse(response.body)
    refute body["report"].key?("render_context"),
           "render_context must be excluded by default (heavy payload)"

    get "/api/reports/#{report.id}", params: { include_context: "true" }, headers: auth_header(@api_key)
    body = JSON.parse(response.body)
    assert body["report"]["render_context"].present?
  end

  # ---------------- CREATE ----------------

  test "POST /api/reports creates a queued report and returns 202" do
    body = {
      report_type: "vendor_scorecard",
      output_format: "pdf",
      parameters: { vendor_id: @vendor.id }
    }

    enqueued = []
    capture = ->(*args, **kwargs) { enqueued << [args, kwargs]; nil }
    Reports::ReportGeneratorJob.singleton_class.send(:define_method, :perform_later, &capture)
    begin
      post "/api/reports", params: body.to_json,
           headers: auth_header(@api_key).merge("Content-Type" => "application/json")
    ensure
      Reports::ReportGeneratorJob.singleton_class.send(:remove_method, :perform_later) rescue nil
    end

    assert_response :accepted
    payload = JSON.parse(response.body)
    assert_equal "queued", payload["report"]["status"]
    assert_equal "vendor_scorecard", payload["report"]["report_type"]
    assert payload["status_url"].present?
    assert_equal 1, enqueued.size, "ReportGeneratorJob.perform_later should have been invoked"
  end

  test "POST /api/reports vendor_scorecard without vendor_id → 400" do
    post "/api/reports",
         params: { report_type: "vendor_scorecard", output_format: "pdf" }.to_json,
         headers: auth_header(@api_key).merge("Content-Type" => "application/json")
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal "VALIDATION_ERROR", body["error"]["code"]
  end

  test "POST /api/reports rejects unknown report_type" do
    post "/api/reports",
         params: { report_type: "nope", output_format: "pdf" }.to_json,
         headers: auth_header(@api_key).merge("Content-Type" => "application/json")
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal "VALIDATION_ERROR", body["error"]["code"]
  end

  test "POST /api/reports rejects unknown output_format" do
    post "/api/reports",
         params: { report_type: "portfolio_risk", output_format: "docx" }.to_json,
         headers: auth_header(@api_key).merge("Content-Type" => "application/json")
    assert_response :bad_request
  end

  test "POST /api/reports cross-tenant vendor_id → 400 (vendor not found in tenant)" do
    post "/api/reports",
         params: { report_type: "vendor_scorecard", output_format: "pdf",
                   parameters: { vendor_id: @other_vendor.id } }.to_json,
         headers: auth_header(@api_key).merge("Content-Type" => "application/json")
    assert_includes [400, 404], response.status
  end

  # ---------------- DOWNLOAD ----------------

  test "GET /api/reports/:id/download streams a ready PDF" do
    file_path = @storage_dir.join("rep.pdf").to_s
    File.binwrite(file_path, "%PDF-1.4 stub-bytes")

    report = create_report(tenant: @tenant, report_type: "vendor_scorecard",
                           output_format: "pdf", status: "ready")
    report.update_columns(storage_path: file_path)

    get "/api/reports/#{report.id}/download", headers: auth_header(@api_key)
    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_includes response.body.to_s, "PDF"
  end

  test "GET /api/reports/:id/download for non-ready report → 404" do
    report = create_report(tenant: @tenant, report_type: "vendor_scorecard",
                           output_format: "pdf", status: "queued")

    get "/api/reports/#{report.id}/download", headers: auth_header(@api_key)
    assert_response :not_found
  end

  test "GET /api/reports/:id/download serves CSV inline payload (small report)" do
    csv_payload = "vendor_id,canonical_name,band,composite_score\n"
    report = create_report(tenant: @tenant, report_type: "portfolio_risk",
                           output_format: "csv", status: "ready")
    report.update_columns(inline_payload: csv_payload, storage_path: nil)

    get "/api/reports/#{report.id}/download", headers: auth_header(@api_key)
    assert_response :success
    assert_match(%r{text/csv}, response.media_type)
    assert_equal csv_payload, response.body
  end

  test "GET /api/reports/:id/download cross-tenant → 404" do
    file_path = @storage_dir.join("ot.pdf").to_s
    File.binwrite(file_path, "%PDF-1.4 stub")
    report = create_report(tenant: @other_tenant, report_type: "vendor_scorecard",
                           output_format: "pdf", status: "ready")
    report.update_columns(storage_path: file_path)

    get "/api/reports/#{report.id}/download", headers: auth_header(@api_key)
    assert_response :not_found
  end

  private

  def auth_header(key)
    { "X-API-Key" => key }
  end

  def create_report(tenant:, report_type:, status:, output_format: "csv")
    report = VendorReport.create!(
      tenant: tenant,
      vendor: report_type == "vendor_scorecard" ? (tenant == @tenant ? @vendor : @other_vendor) : nil,
      report_type: report_type,
      output_format: output_format,
      parameters: {},
      status: "queued"
    )
    if status != "queued"
      report.transition_to!("generating") do |r|
        r.render_context = { schema_version: "vpi.report.v1", tenant: { id: tenant.id } }
        r.tenant_snapshot = { id: tenant.id }
      end
    end
    if status == "ready"
      report.transition_to!("ready") do |r|
        r.generated_at = Time.now.utc
        r.expires_at = 7.days.from_now
      end
    end
    report
  end
end
