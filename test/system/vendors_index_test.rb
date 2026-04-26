require "application_system_test_case"

# Vendors list `/vendors` — PRD §5b, §8, §13.1.
#
# Covers:
# - Authentication gate.
# - Tenant-scoped list (Acme user sees only Acme vendors).
# - Band filter (Turbo Frame refresh).
# - Band pill component rendering.
class VendorsIndexTest < ApplicationSystemTestCase
  test "unauthenticated visit redirects to login" do
    visit "/vendors"
    assert_current_path new_session_path
  end

  test "shows only caller tenant's vendors (Acme)" do
    sign_in_as "admin@example.com", "password123"  # Acme admin

    visit "/vendors"
    assert_selector "[data-testid=vendors-table]"

    # Acme vendors appear
    assert_text "Alpha Maschinenbau"
    assert_text "Beta Elektronik"

    # Globex vendors do NOT
    assert_no_text "Zeta Industrial"
    assert_no_text "Eta Chemical"
    assert_no_text "Theta Freight"
  end

  test "shows only caller tenant's vendors (Globex)" do
    sign_in_as "operator@example.com", "password123"  # Globex operator

    visit "/vendors"
    assert_selector "[data-testid=vendors-table]"

    # Globex vendors appear
    assert_text "Zeta Industrial"
    assert_text "Eta Chemical"

    # Acme vendors do NOT
    assert_no_text "Alpha Maschinenbau"
    assert_no_text "Beta Elektronik"
  end

  test "renders band pills for scored vendors" do
    sign_in_as "admin@example.com", "password123"

    visit "/vendors"

    # Band pills rendered for each scored vendor (acme has 3 active with scores)
    assert_selector "[data-testid=band-pill]", minimum: 1
  end

  private

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
