require "application_system_test_case"

# Vendor Detail `/vendors/:id` — PRD §5b (primary journey steps 3-5), §13.1.
#
# Covers the full operator detail surface: header + score history + top
# contributors + signal timeline + aliases + terminate action. Cross-
# tenant isolation is asserted per PRD §2 invariant 1.
class VendorDetailTest < ApplicationSystemTestCase
  test "unauthenticated visit redirects to login" do
    vendor = vendors(:acme_alpha)
    visit "/vendors/#{vendor.id}"
    assert_current_path new_session_path
  end

  test "renders header + score + band for a scored vendor" do
    sign_in_as "admin@example.com", "password123"
    vendor = vendors(:acme_alpha)

    visit "/vendors/#{vendor.id}"

    assert_selector "[data-testid=vendor-header]"
    assert_selector "[data-testid=vendor-name]", text: "Alpha Maschinenbau"
    assert_selector "[data-testid=band-pill][data-band=low]"
    assert_selector "[data-testid=vendor-score]", text: /15\.5/
  end

  test "renders top contributors from latest score" do
    sign_in_as "admin@example.com", "password123"
    vendor = vendors(:acme_alpha)

    visit "/vendors/#{vendor.id}"

    assert_selector "[data-testid=contributor-table]"
    # acme_alpha_current fixture ships 5 top_contributors rows.
    assert_selector "[data-testid=contributor-row]", count: 5
    assert_text "invoice.late_ratio_30d"
  end

  test "renders recent signals timeline for vendor with signals" do
    sign_in_as "admin@example.com", "password123"
    vendor = vendors(:acme_alpha)

    visit "/vendors/#{vendor.id}"

    assert_selector "[data-testid=signal-timeline]"
    # acme_alpha has 3 signals in fixtures.
    assert_selector "[data-testid=signal-row]", minimum: 3
    assert_text "invoice.late_ratio_30d"
  end

  test "renders empty-state timeline for vendor with no signals" do
    sign_in_as "admin@example.com", "password123"
    vendor = vendors(:acme_gamma)  # no signals in fixtures

    visit "/vendors/#{vendor.id}"

    assert_selector "[data-testid=signal-timeline-empty]"
  end

  test "renders alias card with pending + confirmed rows" do
    sign_in_as "admin@example.com", "password123"
    vendor = vendors(:acme_alpha)

    visit "/vendors/#{vendor.id}"

    assert_selector "[data-testid=alias-card]"
    assert_selector "[data-testid=alias-row]", minimum: 2
    assert_text "ACME-INV-ALPHA-001"
  end

  test "renders score history sparkline when ≥2 snapshots exist" do
    sign_in_as "admin@example.com", "password123"
    vendor = vendors(:acme_alpha)

    visit "/vendors/#{vendor.id}"

    # acme_alpha has 3 score snapshots (current + 2 history) — sparkline renders.
    assert_selector "[data-testid=score-history-svg]"
  end

  test "cross-tenant vendor ID redirects without rendering detail" do
    sign_in_as "admin@example.com", "password123"     # Acme admin
    globex_vendor = vendors(:globex_zeta)

    visit "/vendors/#{globex_vendor.id}"

    # Expect redirect to /vendors (or another safe surface) — MUST NOT render
    # globex vendor name on the page.
    assert_no_text "Zeta Industrial"
  end

  test "terminate button marks vendor as terminated" do
    sign_in_as "admin@example.com", "password123"
    vendor = vendors(:acme_alpha)
    assert_equal "active", vendor.status

    visit "/vendors/#{vendor.id}"
    # accept_confirm handles the turbo_confirm prompt if the driver shows
    # one; if it doesn't (some Playwright versions skip the native confirm
    # for button_to + Turbo), the ModalNotFound means the POST still went
    # through because the click_on inside the block executed first.
    begin
      accept_confirm { click_on "Terminate" }
    rescue Capybara::ModalNotFound
      # click already dispatched; page navigated — nothing more to do.
    end

    # DB-level assertion is the source of truth — does not depend on the
    # post-navigation page state.
    assert_equal "terminated", vendor.reload.status
  end

  private

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
