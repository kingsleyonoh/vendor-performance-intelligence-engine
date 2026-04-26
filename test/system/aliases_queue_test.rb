require "application_system_test_case"

# Aliases Queue UI `/aliases/pending` — PRD §8, §13.3.
#
# Operator-facing pending-confirm queue. Distinct from the JSON
# `Api::VendorAliasesController#pending`. Confirm + Reject route through
# the UI controller (`VendorAliasesController`) which hits the same
# tenant-scoped models.
#
# Covers:
#   - Authentication gate
#   - Tenant isolation (Acme operator sees only Acme pending aliases)
#   - Confirm flips is_confirmed=true and removes the row
#   - Reject deletes the alias and removes the row
#   - Empty state when nothing pending
#   - Sidebar exposes Aliases entry
class AliasesQueueTest < ApplicationSystemTestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    @acme_pending = vendor_aliases(:acme_alpha_secondary)
    refute @acme_pending.is_confirmed, "fixture must be pending"

    # Globex pending alias for cross-tenant assertion
    @globex_pending = VendorAlias.create!(
      tenant: @globex, vendor: vendors(:globex_zeta),
      source_system: "contract_engine", source_ref: "GLOBEX-PEND-#{SecureRandom.hex(3)}",
      alias_text: "Zeta Industrial — pending", confidence: 0.85, is_confirmed: false
    )
  end

  test "unauthenticated visit redirects to login" do
    visit "/aliases/pending"
    assert_current_path new_session_path
  end

  test "Acme operator sees only Acme pending aliases" do
    sign_in_as "admin@example.com", "password123"
    visit "/aliases/pending"

    assert_selector "[data-testid=aliases-table]"
    assert_text @acme_pending.alias_text
    assert_no_text @globex_pending.alias_text
  end

  test "Globex operator sees only Globex pending aliases" do
    sign_in_as "operator@example.com", "password123"
    visit "/aliases/pending"

    assert_selector "[data-testid=aliases-table]"
    assert_text @globex_pending.alias_text
    assert_no_text @acme_pending.alias_text
  end

  test "Confirm flips is_confirmed and removes the row" do
    sign_in_as "admin@example.com", "password123"
    visit "/aliases/pending"

    within "[data-testid=alias-row-#{@acme_pending.id}]" do
      click_on "Confirm"
    end

    @acme_pending.reload
    assert @acme_pending.is_confirmed, "alias must be confirmed"

    visit "/aliases/pending"
    assert_no_selector "[data-testid=alias-row-#{@acme_pending.id}]"
  end

  test "Reject deletes the alias and removes the row" do
    sign_in_as "admin@example.com", "password123"
    visit "/aliases/pending"

    target_id = @acme_pending.id
    within "[data-testid=alias-row-#{target_id}]" do
      click_on "Reject"
    end

    refute VendorAlias.exists?(id: target_id), "alias must be deleted"
    visit "/aliases/pending"
    assert_no_selector "[data-testid=alias-row-#{target_id}]"
  end

  test "empty state shows when no pending aliases" do
    sign_in_as "admin@example.com", "password123"
    VendorAlias.where(tenant_id: @acme.id, is_confirmed: false).delete_all
    visit "/aliases/pending"

    assert_selector "[data-testid=aliases-empty]"
  end

  test "sidebar exposes Aliases entry as active link" do
    sign_in_as "admin@example.com", "password123"
    visit "/"
    assert_selector "[data-testid=sidebar-aliases]"
  end

  private

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
