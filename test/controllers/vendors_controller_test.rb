# frozen_string_literal: true

require "test_helper"

# /vendors (VendorsController#index + #bulk) — PRD §5b, §8.
#
# Tenant-scoping is the invariant under test — Acme requests must NEVER
# surface a Globex vendor, and vice versa.
class VendorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @acme_user = users(:admin)
    @globex_user = users(:operator)
  end

  test "GET /vendors unauthenticated redirects to login" do
    get "/vendors"
    assert_response :redirect
    assert_redirected_to new_session_path
  end

  test "GET /vendors authenticated returns 200" do
    sign_in_as @acme_user
    get "/vendors"
    assert_response :success
  end

  test "Acme sees only Acme vendors" do
    sign_in_as @acme_user
    get "/vendors"

    assert_match(/Alpha Maschinenbau/, response.body)
    assert_match(/Beta Elektronik/, response.body)
    refute_match(/Zeta Industrial/, response.body)
    refute_match(/Eta Chemical/, response.body)
    refute_match(/Theta Freight/, response.body)
  end

  test "Globex sees only Globex vendors" do
    sign_in_as @globex_user
    get "/vendors"

    assert_match(/Zeta Industrial/, response.body)
    assert_match(/Eta Chemical/, response.body)
    refute_match(/Alpha Maschinenbau/, response.body)
    refute_match(/Beta Elektronik/, response.body)
  end

  test "filter by band=critical limits to critical-banded vendors" do
    sign_in_as @acme_user
    get "/vendors", params: { band: ["critical"] }

    # Acme: gamma is banded critical (score 82.0). alpha=low, beta=medium.
    assert_match(/Gamma/, response.body)
    refute_match(/Alpha Maschinenbau/, response.body, "low-banded vendor should be filtered out")
  end

  test "filter by status=active excludes terminated" do
    sign_in_as @acme_user
    get "/vendors", params: { status: ["active"] }

    # delta is terminated — must be excluded.
    refute_match(/Delta Logistik/, response.body)
    assert_match(/Alpha Maschinenbau/, response.body)
  end

  test "POST /vendors/bulk updates multiple vendor categories (tenant-scoped)" do
    sign_in_as @acme_user
    ids = [vendors(:acme_alpha).id, vendors(:acme_beta).id]

    post "/vendors/bulk", params: { vendor_ids: ids, category: "retagged" }
    assert_response :redirect

    assert_equal "retagged", vendors(:acme_alpha).reload.category
    assert_equal "retagged", vendors(:acme_beta).reload.category
    # globex vendor untouched
    assert_not_equal "retagged", vendors(:globex_zeta).reload.category
  end

  test "POST /vendors/bulk cannot update a cross-tenant vendor" do
    sign_in_as @acme_user
    globex_id = vendors(:globex_zeta).id

    post "/vendors/bulk", params: { vendor_ids: [globex_id], category: "hijack" }

    # Either redirects with 0 updated, or returns a safe response — but
    # the globex vendor MUST NOT be mutated by an Acme caller.
    assert_not_equal "hijack", vendors(:globex_zeta).reload.category
  end

  private

  def sign_in_as(user)
    post session_url, params: { email_address: user.email_address, password: "password123" }
  end
end
