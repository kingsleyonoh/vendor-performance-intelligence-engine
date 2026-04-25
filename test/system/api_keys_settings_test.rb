require "application_system_test_case"

# Settings → API Keys `/settings/api-keys` — PRD §5b, §8, §13.3.
#
# Operator-facing key rotation. Calls Tenants::ApiKeyGenerator + atomically
# updates `tenants.api_key_hash` + `tenants.api_key_prefix`. Raw key is
# shown ONCE on the post-rotation page; subsequent visits show only the
# prefix.
#
# Covers:
#   - Authentication gate
#   - Show: prefix only (raw never reads from DB)
#   - Rotate: new key shown once, old prefix invalidated
#   - Reload: only prefix shown
#   - Audit log row written
#   - Cross-tenant isolation
class ApiKeysSettingsTest < ApplicationSystemTestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
  end

  test "unauthenticated visit redirects to login" do
    visit "/settings/api-keys"
    assert_current_path new_session_path
  end

  test "show page displays current api_key_prefix only" do
    sign_in_as "admin@example.com", "password123"
    visit "/settings/api-keys"

    assert_selector "[data-testid=current-api-key-prefix]"
    assert_text @acme.api_key_prefix
  end

  test "Globex operator sees Globex's prefix (tenant isolation)" do
    sign_in_as "operator@example.com", "password123"
    visit "/settings/api-keys"

    assert_text @globex.api_key_prefix
    assert_no_text @acme.api_key_prefix
  end

  test "rotate flow: new raw key shown once, old prefix changes" do
    sign_in_as "admin@example.com", "password123"
    old_prefix = @acme.api_key_prefix

    visit "/settings/api-keys"
    click_on "Rotate API key"

    # New raw key surfaces ONCE
    assert_selector "[data-testid=raw-api-key]"
    new_raw = find("[data-testid=raw-api-key]").text
    assert new_raw.length > 12, "raw key should be longer than just prefix"

    @acme.reload
    refute_equal old_prefix, @acme.api_key_prefix, "prefix must rotate"

    # Reload page — raw must NOT be shown anymore
    visit "/settings/api-keys"
    assert_no_selector "[data-testid=raw-api-key]"
    assert_text @acme.api_key_prefix
  end

  test "rotate writes an audit log entry" do
    sign_in_as "admin@example.com", "password123"

    AuditLogEntry.where(action: "tenant.rotate_key", tenant_id: @acme.id).delete_all

    visit "/settings/api-keys"
    click_on "Rotate API key"

    assert_equal 1, AuditLogEntry.where(action: "tenant.rotate_key", tenant_id: @acme.id).count
  end

  test "sidebar exposes Settings → API Keys entry" do
    sign_in_as "admin@example.com", "password123"
    visit "/"
    assert_selector "[data-testid=sidebar-settings-api-keys]"
  end

  private

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
