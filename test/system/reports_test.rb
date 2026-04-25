require "application_system_test_case"

# Reports UI `/reports` — PRD §5b, §8, §13.3.
#
# Operator-facing surface for report generation + download. Covers:
# - Authentication gate (login redirect)
# - Tenant-scoped list (Acme operator sees only Acme reports)
# - Generate modal (vendor_scorecard with vendor picker, portfolio_risk)
# - Download link routing
# - Sidebar Reports nav entry is now active (no longer "(soon)")
class ReportsTest < ApplicationSystemTestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    @acme_alpha = vendors(:acme_alpha)
    @globex_eta = vendors(:globex_eta)

    seed_reports!
  end

  test "unauthenticated visit redirects to login" do
    visit "/reports"
    assert_current_path new_session_path
  end

  test "Acme operator sees only Acme reports (tenant isolation)" do
    sign_in_as "admin@example.com", "password123"
    visit "/reports"

    assert_selector "[data-testid=reports-table]"
    assert_text "portfolio_risk"
    # Acme report title contains acme vendor name; globex's must not appear
    assert_no_text "Eta Chemical"
    # globex display name MUST NOT appear in chrome (operator is acme)
    assert_no_text "Globex International"
  end

  test "Globex operator sees only Globex reports (tenant isolation)" do
    sign_in_as "operator@example.com", "password123"
    visit "/reports"

    assert_selector "[data-testid=reports-table]"
    # Acme rows must NOT appear
    assert_no_text "Alpha Maschinenbau AG"
    assert_no_text "Acme Procurement GmbH"
  end

  test "sidebar exposes Reports nav entry as active link" do
    sign_in_as "admin@example.com", "password123"
    visit "/"
    assert_selector "[data-testid=sidebar-reports]"
  end

  test "generate modal: portfolio_risk creates a queued report row" do
    sign_in_as "admin@example.com", "password123"
    visit "/reports"

    click_on "Generate"
    assert_selector "[data-testid=generate-modal]"

    select "portfolio_risk", from: "report_type"
    select "csv",            from: "output_format"
    click_on "Submit"

    assert_text "queued"
    assert_current_path "/reports"
  end

  test "ready report shows Download action" do
    sign_in_as "admin@example.com", "password123"
    visit "/reports"

    # The seeded ready_report has a Download action.
    assert_selector "[data-testid=download-link]", minimum: 1
  end

  private

  def seed_reports!
    # Acme — one queued, one ready
    queued = VendorReport.create!(
      tenant: @acme, vendor: @acme_alpha,
      report_type: "vendor_scorecard", output_format: "pdf",
      parameters: {}, status: "queued"
    )
    queued.transition_to!("generating") do |r|
      r.render_context = { schema_version: "vpi.report.v1", tenant: { id: @acme.id, display_name: "Acme" } }
      r.tenant_snapshot = { id: @acme.id, display_name: "Acme" }
    end
    queued.update!(status: "queued")  # still queued for the test, but with snapshots

    # Acme ready
    ready = VendorReport.create!(
      tenant: @acme,
      report_type: "portfolio_risk", output_format: "csv",
      parameters: {}, status: "queued"
    )
    ready.transition_to!("generating") do |r|
      r.render_context = { schema_version: "vpi.report.v1", tenant: { id: @acme.id, display_name: "Acme" } }
      r.tenant_snapshot = { id: @acme.id, display_name: "Acme" }
    end
    ready.transition_to!("ready") do |r|
      r.storage_path = "/tmp/test_ready.csv"
      r.inline_payload = "vendor_id,canonical_name,band,composite_score\n"
      r.generated_at = Time.now.utc
      r.expires_at   = 7.days.from_now
    end

    # Globex — one ready
    g = VendorReport.create!(
      tenant: @globex,
      report_type: "portfolio_risk", output_format: "csv",
      parameters: {}, status: "queued"
    )
    g.transition_to!("generating") do |r|
      r.render_context = { schema_version: "vpi.report.v1", tenant: { id: @globex.id, display_name: "Globex" } }
      r.tenant_snapshot = { id: @globex.id, display_name: "Globex" }
    end
    g.transition_to!("ready") do |r|
      r.storage_path = "/tmp/test_globex.csv"
      r.inline_payload = "vendor_id,canonical_name\n"
      r.generated_at = Time.now.utc
      r.expires_at   = 7.days.from_now
    end
  end

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
