# frozen_string_literal: true

require "test_helper"

# IngestionSource — PRD §4. One row per (tenant, source_system) tuple
# describing how a tenant connects to an upstream signal producer.
class IngestionSourceTest < ActiveSupport::TestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
  end

  test "creates with required attributes" do
    source = IngestionSource.create!(
      tenant: @acme,
      source_system: "invoice_recon",
      is_enabled: true,
      pull_mode: "periodic",
      pull_interval_minutes: 15
    )

    assert source.persisted?
    assert_equal "invoice_recon", source.source_system
    assert_equal({}, source.connection_config)
  end

  test "tenant scoping — sources are isolated per tenant" do
    IngestionSource.create!(tenant: @acme, source_system: "invoice_recon", pull_mode: "periodic")
    IngestionSource.create!(tenant: @globex, source_system: "invoice_recon", pull_mode: "periodic")

    assert_equal 1, IngestionSource.where(tenant_id: @acme.id).count
    assert_equal 1, IngestionSource.where(tenant_id: @globex.id).count
  end

  test "uniqueness — at most one source per (tenant, source_system)" do
    IngestionSource.create!(tenant: @acme, source_system: "webhook_engine", pull_mode: "periodic")

    duplicate = IngestionSource.new(tenant: @acme, source_system: "webhook_engine", pull_mode: "periodic")
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "different source_systems for the same tenant are allowed" do
    IngestionSource.create!(tenant: @acme, source_system: "webhook_engine", pull_mode: "periodic")
    second = IngestionSource.create!(tenant: @acme, source_system: "contract_engine", pull_mode: "periodic")
    assert second.persisted?
  end

  test "rejects unknown source_system at the model layer" do
    src = IngestionSource.new(tenant: @acme, source_system: "unknown_system", pull_mode: "periodic")
    refute src.valid?
    assert_includes src.errors[:source_system], "is not included in the list"
  end

  test "rejects unknown pull_mode" do
    src = IngestionSource.new(tenant: @acme, source_system: "invoice_recon", pull_mode: "telepathy")
    refute src.valid?
    assert_includes src.errors[:pull_mode], "is not included in the list"
  end

  test "is_enabled defaults to false (standalone-first per PRD §2.2)" do
    src = IngestionSource.create!(tenant: @acme, source_system: "rag_platform", pull_mode: "periodic")
    refute src.is_enabled
  end

  test "connection_config stores arbitrary jsonb" do
    src = IngestionSource.create!(
      tenant: @acme,
      source_system: "invoice_recon",
      pull_mode: "periodic",
      connection_config: { base_url_env: "INVOICE_RECON_URL", api_key_env: "INVOICE_RECON_API_KEY" }
    )
    src.reload
    assert_equal "INVOICE_RECON_URL", src.connection_config["base_url_env"]
  end

  test "tenant_id is required" do
    src = IngestionSource.new(source_system: "invoice_recon", pull_mode: "periodic")
    refute src.valid?
  end

  test "scope :enabled returns only enabled sources for current tenant" do
    enabled = IngestionSource.create!(tenant: @acme, source_system: "invoice_recon", pull_mode: "periodic", is_enabled: true)
    IngestionSource.create!(tenant: @acme, source_system: "webhook_engine", pull_mode: "periodic", is_enabled: false)

    result = IngestionSource.where(tenant_id: @acme.id).where(is_enabled: true)
    assert_equal [enabled.id], result.pluck(:id)
  end
end
