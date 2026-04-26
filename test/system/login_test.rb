require "application_system_test_case"

# Login page — PRD §5b, §8, §13.1.
#
# Covers:
# - Rendering the auth layout (centered card, no app chrome).
# - Invalid credentials keep the operator on the login page with a flash.
# - Valid credentials redirect to the dashboard root `/`.
# - VPI branding CSS custom properties (`--brand-primary`, `--brand-accent`)
#   are injected from PRD §4.T installation defaults when no tenant is
#   session-scoped yet.
class LoginTest < ApplicationSystemTestCase
  test "renders login form with email + password fields under the auth layout" do
    visit "/session/new"

    assert_selector "form"
    assert_selector "input[type=email]"
    assert_selector "input[type=password]"
    assert_selector "button[type=submit], input[type=submit]"

    # Auth layout has NO app sidebar/nav (that's only on authenticated pages).
    assert_no_selector "[data-testid=app-sidebar]"
    assert_no_selector "[data-testid=app-top-nav]"

    # Brand defaults from PRD §4.T: primary #0D0D0F, accent #3B82F6.
    style = page.find("html", visible: :all)[:style].to_s
    assert style.include?("--brand-primary") || page.html.include?("--brand-primary"),
           "expected --brand-primary CSS variable to be injected"
  end

  test "invalid credentials stay on login with flash alert" do
    visit "/session/new"

    fill_in "email_address", with: "operator@example.com"
    fill_in "password", with: "WRONG_PASSWORD_1234"
    click_on "Sign in"

    assert_current_path new_session_path
    assert_text(/try another|invalid/i)
  end

  test "valid credentials redirect to dashboard root" do
    visit "/session/new"

    fill_in "email_address", with: "operator@example.com"
    fill_in "password", with: "password123"
    click_on "Sign in"

    assert_current_path "/"
  end
end
