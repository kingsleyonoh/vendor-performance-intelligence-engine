# frozen_string_literal: true

require "test_helper"

# /  (DashboardController#index) — PRD §5b, §8.
#
# - Authentication gate (unauthenticated → 302 to /session/new).
# - KPI counts are tenant-scoped (Acme sees only Acme data).
class DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    @acme_user = users(:admin)       # Acme operator
    @globex_user = users(:operator)  # Globex operator
  end

  test "GET / unauthenticated redirects to login" do
    get "/"
    assert_response :redirect
    assert_redirected_to new_session_path
  end

  test "GET / authenticated renders 200" do
    sign_in_as @acme_user
    get "/"
    assert_response :success
  end

  test "Acme user sees only Acme vendor counts" do
    sign_in_as @acme_user
    get "/"

    # Fixtures: Acme has 4 vendors (alpha, beta, gamma, delta)
    # - 2 active: alpha, beta
    # - 1 watchlist: gamma
    # - 1 terminated: delta
    assert_match(/4/, response.body, "expected total vendor count of 4 for Acme")
  end

  test "Globex user sees only Globex vendor counts" do
    sign_in_as @globex_user
    get "/"

    # Fixtures: Globex has 3 vendors (zeta, eta, theta — all active).
    # Assert on tenant display_name isolation:
    assert_match(/Globex/, response.body)
    refute_match(/Alpha Maschinenbau/, response.body, "cross-tenant vendor leaked")
    refute_match(/Beta Elektronik/, response.body, "cross-tenant vendor leaked")
  end

  private

  def sign_in_as(user)
    post session_url, params: { email_address: user.email_address, password: "password123" }
  end
end
