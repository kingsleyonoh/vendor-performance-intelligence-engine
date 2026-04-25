require "application_system_test_case"

# Audit Log UI `/audit` — PRD §5b, §8, §13.3.
#
# Operator-facing read-only audit trail. Tenant-scoped. Per Batch 007
# design, all UI users are admins (no per-user role in v1) — the access
# gate is therefore session authentication.
class AuditLogUiTest < ApplicationSystemTestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    AuditLogEntry.where(tenant_id: [@acme.id, @globex.id]).delete_all
    seed_audit!
  end

  test "unauthenticated visit redirects to login" do
    visit "/audit"
    assert_current_path new_session_path
  end

  test "Acme operator sees only Acme audit rows (tenant isolation)" do
    sign_in_as "admin@example.com", "password123"

    visit "/audit"
    assert_selector "[data-testid=audit-log-table]"

    # Acme rows are visible
    assert_text "vendors#create"
    assert_text "scoring_rules#activate"

    # Globex action does not leak in
    assert_no_text "tenant.rotate_key"
  end

  test "Globex operator sees only Globex audit rows (tenant isolation)" do
    sign_in_as "operator@example.com", "password123"

    visit "/audit"
    assert_selector "[data-testid=audit-log-table]"
    assert_text "tenant.rotate_key"

    # Acme actions do not leak in
    assert_no_text "vendors#create"
    assert_no_text "scoring_rules#activate"
  end

  test "renders rows with action + entity_type + occurred_at columns" do
    sign_in_as "admin@example.com", "password123"
    visit "/audit"

    assert_selector "[data-testid=audit-row]", minimum: 2
  end

  test "sidebar exposes Audit nav entry" do
    sign_in_as "admin@example.com", "password123"

    visit "/"
    assert_selector "[data-testid=sidebar-audit]"
  end

  test "renders empty state when tenant has no audit rows" do
    AuditLogEntry.where(tenant_id: @acme.id).delete_all
    sign_in_as "admin@example.com", "password123"

    visit "/audit"
    assert_selector "[data-testid=audit-log-empty]"
  end

  private

  def seed_audit!
    AuditLogEntry.append!(
      tenant_id:   @acme.id, actor_type: "Tenant", actor_id: @acme.id,
      action:      "vendors#create", entity_type: "Vendor",
      entity_id:   SecureRandom.uuid, occurred_at: 1.hour.ago
    )
    AuditLogEntry.append!(
      tenant_id:   @acme.id, actor_type: "Tenant", actor_id: @acme.id,
      action:      "scoring_rules#activate", entity_type: "ScoringRule",
      entity_id:   SecureRandom.uuid, occurred_at: 30.minutes.ago
    )
    AuditLogEntry.append!(
      tenant_id:   @globex.id, actor_type: "Tenant", actor_id: @globex.id,
      action:      "tenant.rotate_key", entity_type: "Tenant",
      entity_id:   @globex.id, occurred_at: 5.minutes.ago
    )
  end

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
