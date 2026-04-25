require "application_system_test_case"

# Settings → Scoring Rules `/settings/scoring` — PRD §5b, §8, §13.3.
#
# Operator-facing config surface for tuning category weights + band
# thresholds. Mirror of the JSON `Api::ScoringRulesController`.
#
# Covers:
#   - Authentication gate
#   - Active rule shown for Current.tenant
#   - Cross-tenant isolation (Acme operator sees only Acme rule)
#   - Sidebar exposes Settings → Scoring entry
#   - Save creates a new rule and activates it (deactivates old)
#   - Invalid weights (sum != 1.00) re-renders form with error
class ScoringRulesSettingsTest < ApplicationSystemTestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    @acme_rule = scoring_rules(:acme_default)
    @globex_rule = scoring_rules(:globex_default)
  end

  test "unauthenticated visit redirects to login" do
    visit "/settings/scoring"
    assert_current_path new_session_path
  end

  test "Acme operator sees only Acme rule" do
    sign_in_as "admin@example.com", "password123"
    visit "/settings/scoring"

    assert_selector "[data-testid=scoring-rule-form]"
    assert_text "Default v1"           # acme rule name
    assert_no_text "Default v1 (Globex)"
  end

  test "Globex operator sees only Globex rule" do
    sign_in_as "operator@example.com", "password123"
    visit "/settings/scoring"

    assert_selector "[data-testid=scoring-rule-form]"
    assert_text "Default v1 (Globex)"
    assert_no_text "Default v1\n"  # Acme's name shouldn't appear standalone
  end

  test "sidebar exposes Settings → Scoring entry" do
    sign_in_as "admin@example.com", "password123"

    visit "/"
    assert_selector "[data-testid=sidebar-settings]"
    assert_selector "[data-testid=sidebar-settings-scoring]"
  end

  test "submitting valid weights creates a new rule and activates it" do
    sign_in_as "admin@example.com", "password123"
    visit "/settings/scoring"

    fill_in "scoring_rule[name]",                                   with: "Tuned v2"
    fill_in "scoring_rule[category_weights][financial]",            with: "0.40"
    fill_in "scoring_rule[category_weights][operational]",          with: "0.10"
    fill_in "scoring_rule[category_weights][contractual]",          with: "0.30"
    fill_in "scoring_rule[category_weights][integration]",          with: "0.15"
    fill_in "scoring_rule[category_weights][transactional]",        with: "0.05"
    fill_in "scoring_rule[band_thresholds][low_max]",               with: "25"
    fill_in "scoring_rule[band_thresholds][medium_max]",            with: "50"
    fill_in "scoring_rule[band_thresholds][high_max]",              with: "75"
    fill_in "scoring_rule[window_days]",                            with: "90"
    fill_in "scoring_rule[time_decay_half_life_days]",              with: "45"

    assert_difference -> { ScoringRule.where(tenant_id: @acme.id).count }, 1 do
      click_on "Save and activate"
    end

    new_rule = ScoringRule.where(tenant_id: @acme.id, name: "Tuned v2").first
    assert new_rule.is_active, "new rule must be activated"
    @acme_rule.reload
    refute @acme_rule.is_active, "previously-active rule must be deactivated"
  end

  test "invalid weights (sum != 1.00) re-renders form with error" do
    sign_in_as "admin@example.com", "password123"
    visit "/settings/scoring"

    fill_in "scoring_rule[category_weights][financial]",            with: "0.50"
    fill_in "scoring_rule[category_weights][operational]",          with: "0.50"
    fill_in "scoring_rule[category_weights][contractual]",          with: "0.50"
    fill_in "scoring_rule[category_weights][integration]",          with: "0.10"
    fill_in "scoring_rule[category_weights][transactional]",        with: "0.10"

    click_on "Save and activate"

    assert_text(/sum to 1\.00|category_weights/i)
  end

  private

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
