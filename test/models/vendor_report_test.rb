# frozen_string_literal: true

require "test_helper"

# VendorReport — PRD §4.9. Generated report rows. tenant_snapshot +
# render_context are FROZEN at queued → generating transition (PRD §5.6).
# Subsequent re-renders bind to those columns, never re-query live data.
class VendorReportTest < ActiveSupport::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @vendor = vendors(:acme_alpha)
    @other_tenant = tenants(:globex_inc_us)
  end

  # ---------------- Happy path ----------------
  test "creates a queued vendor_scorecard report with required fields" do
    report = VendorReport.create!(
      tenant: @tenant,
      vendor: @vendor,
      report_type: "vendor_scorecard",
      output_format: "pdf",
      parameters: { "window_days" => 90 }
    )

    assert report.persisted?
    assert_equal "queued", report.status
    assert_equal "vendor_scorecard", report.report_type
    assert_equal "pdf", report.output_format
    assert_equal({ "window_days" => 90 }, report.parameters)
    assert_equal({}, report.tenant_snapshot)
    assert_equal({}, report.render_context)
  end

  # ---------------- Required fields ----------------
  test "rejects a report without tenant" do
    report = VendorReport.new(
      report_type: "portfolio_risk",
      output_format: "csv"
    )
    refute report.valid?
    assert report.errors[:tenant].present?
  end

  test "rejects a report without report_type" do
    report = VendorReport.new(tenant: @tenant, output_format: "pdf")
    refute report.valid?
    assert report.errors[:report_type].present?
  end

  test "rejects an unknown report_type" do
    report = VendorReport.new(
      tenant: @tenant, vendor: @vendor,
      report_type: "garbage_type", output_format: "pdf"
    )
    refute report.valid?
    assert report.errors[:report_type].present?
  end

  test "rejects an unknown output_format" do
    report = VendorReport.new(
      tenant: @tenant, vendor: @vendor,
      report_type: "vendor_scorecard", output_format: "docx"
    )
    refute report.valid?
    assert report.errors[:output_format].present?
  end

  test "rejects an unknown status" do
    report = VendorReport.new(
      tenant: @tenant, vendor: @vendor,
      report_type: "vendor_scorecard", output_format: "pdf",
      status: "weird"
    )
    refute report.valid?
    assert report.errors[:status].present?
  end

  # ---------------- vendor_id nullable for tenant-scoped reports ----------------
  test "portfolio_risk report can have null vendor_id" do
    report = VendorReport.create!(
      tenant: @tenant, vendor: nil,
      report_type: "portfolio_risk", output_format: "csv"
    )
    assert report.persisted?
    assert_nil report.vendor_id
  end

  # ---------------- Status transitions ----------------
  test "status transitions queued -> generating -> ready" do
    report = create_report
    assert_equal "queued", report.status

    report.transition_to!("generating")
    assert_equal "generating", report.reload.status

    report.transition_to!("ready")
    assert_equal "ready", report.reload.status
  end

  test "status transition queued -> generating -> failed" do
    report = create_report
    report.transition_to!("generating")
    report.transition_to!("failed")
    assert_equal "failed", report.reload.status
  end

  test "status transition ready -> expired" do
    report = create_report(status: "ready")
    report.transition_to!("expired")
    assert_equal "expired", report.reload.status
  end

  test "rejects illegal status transitions" do
    report = create_report
    assert_raises(VendorReport::InvalidStatusTransition) do
      report.transition_to!("ready") # queued cannot jump straight to ready
    end
  end

  # ---------------- Snapshot append-only ----------------
  test "tenant_snapshot is frozen once set (cannot be replaced with a different value)" do
    report = create_report
    snapshot = { "id" => @tenant.id, "legal_name" => "Acme GmbH" }
    report.update!(tenant_snapshot: snapshot)

    report.tenant_snapshot = { "legal_name" => "Tampered Corp" }
    refute report.valid?
    assert report.errors[:tenant_snapshot].present?,
           "tenant_snapshot must reject overwrites once populated"
  end

  test "render_context is frozen once set" do
    report = create_report
    ctx = { "schema_version" => "vpi.report.v1", "tenant" => { "id" => @tenant.id } }
    report.update!(render_context: ctx)

    report.render_context = { "schema_version" => "tampered" }
    refute report.valid?
    assert report.errors[:render_context].present?
  end

  test "tenant_snapshot can be set from empty default once" do
    report = create_report
    snapshot = { "id" => @tenant.id }
    report.update!(tenant_snapshot: snapshot)
    assert_equal snapshot, report.reload.tenant_snapshot
  end

  # ---------------- Tenant isolation ----------------
  test "scoping by tenant returns only that tenant's reports" do
    own = create_report
    create_report(tenant: @other_tenant)

    own_scope = VendorReport.where(tenant_id: @tenant.id)
    assert_includes own_scope, own
    assert_equal 1, own_scope.count
  end

  test "string representation includes id and report_type" do
    report = create_report
    s = report.to_s
    assert_includes s, report.id
    assert_includes s, "vendor_scorecard"
  end

  private

  def create_report(tenant: @tenant, status: "queued")
    VendorReport.create!(
      tenant: tenant,
      vendor: tenant == @tenant ? @vendor : vendors(:globex_zeta),
      report_type: "vendor_scorecard",
      output_format: "pdf",
      parameters: {},
      status: status
    )
  end
end
