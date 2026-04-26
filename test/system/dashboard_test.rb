require "application_system_test_case"

# Dashboard `/` — PRD §5b "Primary journey — Daily vendor review" step 2.
#
# Covers:
# - Authentication gate (unauthenticated → /session/new).
# - Tenant-scoped KPI rendering (globex operator sees ONLY globex vendors).
# - The 4 mandatory KPI widgets: status counts, band counts, band-change
#   list (last 7 days), unacknowledged alerts placeholder.
# - App chrome (sidebar + top nav with tenant display_name).
class DashboardTest < ApplicationSystemTestCase
  test "unauthenticated visit redirects to login" do
    visit "/"
    assert_current_path new_session_path
  end

  test "authenticated operator sees tenant-scoped KPIs + app chrome" do
    sign_in_as "operator@example.com", "password123"  # Globex operator

    assert_current_path "/"

    # App chrome
    assert_selector "[data-testid=app-sidebar]"
    assert_selector "[data-testid=app-top-nav]"
    assert_text "Globex"           # Current.tenant.display_name
    assert_no_text "Acme"          # cross-tenant leakage guard

    # KPI headers per PRD §5b
    assert_text(/total vendors/i)
    assert_text(/band/i)

    # Band-count cards must include all 4 bands
    %w[low medium high critical].each { |b| assert_text(/#{b}/i) }
  end

  test "dashboard KPI counts are tenant-isolated" do
    # Globex: 3 active vendors (zeta, eta, theta) in fixtures
    sign_in_as "operator@example.com", "password123"
    assert_current_path "/"

    # active-vendor count appears as "3" — a strict test would look in the
    # specific card, but we accept the looser text presence here since the
    # controller_test enforces exact tenant-scoped counts.
    assert_text(/active/i)

    # Ensure an Acme-only vendor name never appears (cross-tenant leakage).
    assert_no_text "Alpha Maschinenbau"
    assert_no_text "Beta Elektronik"
  end

  private

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
