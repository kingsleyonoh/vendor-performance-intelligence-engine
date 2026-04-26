require "application_system_test_case"

# Settings → Ingestion Sources `/settings/ingestion-sources` — PRD §8, §13.2.
#
# Operator-facing config surface for adapter onboarding. Covers:
#   - Authentication gate
#   - Tenant isolation (Acme operator sees only Acme sources)
#   - Sidebar exposes the Settings → Ingestion Sources entry
#   - "New" form rejects raw secrets via SourceContract validation
#   - Toggle is_enabled via edit form
#   - "Pull Now" button creates an ingestion_run
class IngestionSourcesSettingsTest < ApplicationSystemTestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)

    @acme_source = IngestionSource.create!(
      tenant: @acme, source_system: "webhook_engine", is_enabled: true,
      connection_config: { "base_url" => "https://acme.example",
                           "api_key_ref" => "ENV:WEBHOOK_ENGINE_API_KEY" },
      pull_mode: "periodic"
    )

    @globex_source = IngestionSource.create!(
      tenant: @globex, source_system: "invoice_recon", is_enabled: true,
      connection_config: { "base_url" => "https://globex.example",
                           "api_key_ref" => "ENV:INVOICE_RECON_API_KEY" },
      pull_mode: "periodic"
    )
  end

  test "unauthenticated visit redirects to login" do
    visit "/settings/ingestion-sources"
    assert_current_path new_session_path
  end

  test "Acme operator sees only Acme sources (tenant isolation)" do
    sign_in_as "admin@example.com", "password123"

    visit "/settings/ingestion-sources"
    assert_selector "[data-testid=ingestion-sources-table]"

    assert_text "webhook_engine"     # Acme's source
    assert_no_text "invoice_recon"   # Globex's source — must NOT appear
  end

  test "Globex operator sees only Globex sources (tenant isolation)" do
    sign_in_as "operator@example.com", "password123"

    visit "/settings/ingestion-sources"
    assert_selector "[data-testid=ingestion-sources-table]"

    assert_text "invoice_recon"
    assert_no_text "webhook_engine"
  end

  test "sidebar exposes Settings → Ingestion Sources nav entry" do
    sign_in_as "admin@example.com", "password123"

    visit "/"
    assert_selector "[data-testid=sidebar-settings]"
    assert_selector "[data-testid=sidebar-settings-ingestion-sources]"
  end

  test "new source form rejects raw api_key with validation error" do
    sign_in_as "admin@example.com", "password123"

    visit "/settings/ingestion-sources/new"
    select "contract_engine", from: "ingestion_source[source_system]"
    fill_in "ingestion_source[connection_config_json]",
            with: '{"base_url":"https://contract.example","api_key":"raw-secret-leaked"}'
    click_on "Create"

    # Stays on the form / re-rendered with error
    assert_text(/raw secret detected|api_key_ref/i)
  end

  test "new source form accepts ENV-ref secret" do
    sign_in_as "admin@example.com", "password123"

    assert_difference -> { IngestionSource.where(tenant_id: @acme.id).count }, 1 do
      visit "/settings/ingestion-sources/new"
      select "contract_engine", from: "ingestion_source[source_system]"
      fill_in "ingestion_source[connection_config_json]",
              with: '{"base_url":"https://contract.example","api_key_ref":"ENV:CONTRACT_ENGINE_API_KEY"}'
      click_on "Create"
    end

    assert_text(/created|saved/i)
  end

  test "edit form toggles is_enabled" do
    sign_in_as "admin@example.com", "password123"

    visit "/settings/ingestion-sources/#{@acme_source.id}/edit"
    uncheck "ingestion_source[is_enabled]"
    click_on "Save"

    @acme_source.reload
    refute @acme_source.is_enabled, "expected source to be disabled"
  end

  test "Pull Now button creates an ingestion_run" do
    sign_in_as "admin@example.com", "password123"

    assert_difference -> { IngestionRun.where(ingestion_source_id: @acme_source.id).count }, 1 do
      visit "/settings/ingestion-sources/#{@acme_source.id}"
      click_on "Pull Now"
    end

    assert_text(/queued|running/i)
  end

  private

  def sign_in_as(email, password)
    visit "/session/new"
    fill_in "email_address", with: email
    fill_in "password", with: password
    click_on "Sign in"
  end
end
