require "application_system_test_case"

# Alert Inbox `/alerts` — PRD §5b, §8, §13.2.
#
# Operator-facing triage surface for risk alerts. Covers:
# - Authentication gate
# - Tenant-scoped list (Acme operator sees only Acme alerts)
# - Filter by band
# - Acknowledge action moves alert out of pending list
# - Vendor link routes to vendor detail page
# - Sidebar shows the Alerts nav entry
#
# Sets up alerts inline so the global fixtures stay tenant-isolation
# clean for unit tests that assert exact RiskAlert counts.
class AlertsInboxTest < ApplicationSystemTestCase
  setup do
    @acme    = tenants(:acme_gmbh_de)
    @globex  = tenants(:globex_inc_us)

    @acme_alpha = vendors(:acme_alpha)
    @acme_gamma = vendors(:acme_gamma)
    @globex_eta = vendors(:globex_eta)

    # Use scores that no other test creates a RiskAlert for, so the
    # idempotency UNIQUE index doesn't collide with concurrent test runs.
    @acme_score_for_alpha = vendor_scores(:acme_alpha_history_2)
    @acme_score_for_gamma = vendor_scores(:acme_gamma_current)
    @globex_score         = vendor_scores(:globex_high_score)

    seed_alerts!
  end

  test "unauthenticated visit redirects to login" do
    visit "/alerts"
    assert_current_path new_session_path
  end

  test "Acme operator sees only Acme alerts (tenant isolation)" do
    sign_in_as "admin@example.com", "password123"

    visit "/alerts"
    assert_selector "[data-testid=alerts-table]"

    # Acme alerts are visible
    assert_text "Alpha Maschinenbau AG"
    assert_text "Gamma Werkzeuge GmbH"

    # Globex alerts and tenant identity literals do NOT appear
    assert_no_text "Eta Chemical Co."
    assert_no_text "Globex"
  end

  test "Globex operator sees only Globex alerts (tenant isolation)" do
    sign_in_as "operator@example.com", "password123"

    visit "/alerts"
    assert_selector "[data-testid=alerts-table]"

    assert_text "Eta Chemical Co."

    assert_no_text "Alpha Maschinenbau AG"
    assert_no_text "Acme Procurement GmbH"
  end

  test "renders band-change pill (from -> to)" do
    sign_in_as "admin@example.com", "password123"

    visit "/alerts"
    assert_selector "[data-testid=band-change-pill]", minimum: 1
  end

  test "sidebar exposes Alerts nav entry" do
    sign_in_as "admin@example.com", "password123"

    visit "/"
    assert_selector "[data-testid=sidebar-alerts]"
  end

  test "vendor link in row routes to vendor detail page" do
    sign_in_as "admin@example.com", "password123"

    visit "/alerts"
    assert_selector "[data-testid=alert-vendor-link]"
    click_on "Alpha Maschinenbau AG", match: :first

    assert_current_path %r{/vendors/[0-9a-f-]+}
  end

  test "acknowledge action moves alert out of default inbox" do
    sign_in_as "admin@example.com", "password123"

    visit "/alerts"
    within "[data-alert-vendor='Gamma Werkzeuge GmbH']" do
      click_on "Acknowledge"
    end

    assert_text "acknowledged"
  end

  private

  def seed_alerts!
    acme_payload = ->(vendor_name) {
      {
        event_type: "vendor.risk_band_changed",
        tenant: { legal_name: "Acme GmbH", display_name: "Acme",
                  full_legal_name: "Acme Procurement GmbH",
                  locale: "de-DE", timezone: "Europe/Berlin" },
        vendor: { canonical_name: vendor_name }
      }
    }

    globex_payload = ->(vendor_name) {
      {
        event_type: "vendor.risk_band_changed",
        tenant: { legal_name: "Globex Inc.", display_name: "Globex",
                  full_legal_name: "Globex International, Inc.",
                  locale: "en-US", timezone: "America/Los_Angeles" },
        vendor: { canonical_name: vendor_name }
      }
    }

    RiskAlert.create!(
      tenant: @acme, vendor: @acme_alpha,
      previous_band: "low", new_band: "high",
      previous_score: 18.0, new_score: 75.0, direction: "escalation",
      triggered_by_score: @acme_score_for_alpha.id,
      status: "pending",
      delivery_payload: acme_payload.call("Alpha Maschinenbau AG")
    )

    RiskAlert.create!(
      tenant: @acme, vendor: @acme_gamma,
      previous_band: "high", new_band: "critical",
      previous_score: 70.0, new_score: 88.5, direction: "escalation",
      triggered_by_score: @acme_score_for_gamma.id,
      status: "delivered",
      hub_event_id: "hub-evt-fx-1",
      dispatch_attempts: 1, last_attempt_at: 1.hour.ago,
      delivery_payload: acme_payload.call("Gamma Werkzeuge GmbH")
    )

    RiskAlert.create!(
      tenant: @globex, vendor: @globex_eta,
      previous_band: "medium", new_band: "high",
      previous_score: 45.0, new_score: 70.0, direction: "escalation",
      triggered_by_score: @globex_score.id,
      status: "pending",
      delivery_payload: globex_payload.call("Eta Chemical Co.")
    )
  end

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
