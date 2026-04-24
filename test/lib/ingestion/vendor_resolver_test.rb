# frozen_string_literal: true

require "test_helper"

# Ingestion::VendorResolver — PRD §5.2. Every inbound signal passes through
# this resolver to translate `(source_system, source_ref, hints)` into a
# canonical `vendor_id`. The auto-match priority ladder from PRD is:
#
#   1. Existing alias hit on (tenant, source_system, source_ref)
#   2. tax_id exact match      -> confidence 1.00, auto-confirmed
#   3. normalized_name exact   -> confidence 0.85, pending operator confirm
#   4. Levenshtein <= threshold-> confidence 0.70, pending operator confirm
#   5. No match                -> create new vendor, confidence 1.00
class VendorResolverTest < ActiveSupport::TestCase
  def setup
    @acme = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
  end

  def resolve(overrides = {})
    defaults = {
      tenant: @acme,
      source_system: "invoice_recon",
      source_ref: "test-ref-#{SecureRandom.hex(4)}",
      name: nil,
      tax_id: nil,
      country_code: nil
    }
    Ingestion::VendorResolver.resolve(**defaults.merge(overrides))
  end

  # --------------------------------------------------------------------
  # Rung 1: existing alias hit
  # --------------------------------------------------------------------

  test "returns existing alias when (tenant, source_system, source_ref) matches" do
    existing_vendor = Vendor.create!(tenant: @acme, canonical_name: "Existing Co")
    existing_alias = VendorAlias.create!(
      tenant: @acme,
      vendor: existing_vendor,
      source_system: "invoice_recon",
      source_ref: "cached-001",
      confidence: 1.0,
      is_confirmed: true
    )

    result = resolve(source_ref: "cached-001", name: "Different Name")

    assert_equal existing_vendor.id, result[:vendor].id
    assert_equal existing_alias.id, result[:alias].id
    assert_equal false, result[:was_created]
  end

  test "idempotent re-resolve of same (source_system, source_ref) returns same alias" do
    first = resolve(source_ref: "idem-001", name: "Widgets Inc")
    second = resolve(source_ref: "idem-001", name: "Widgets Inc")

    assert_equal first[:vendor].id, second[:vendor].id
    assert_equal first[:alias].id, second[:alias].id
  end

  # --------------------------------------------------------------------
  # Rung 2: tax_id exact match (1.00, auto-confirmed)
  # --------------------------------------------------------------------

  test "exact tax_id match yields confidence 1.00 and auto-confirmed alias" do
    vendor = Vendor.create!(tenant: @acme, canonical_name: "TaxMatch Co", tax_id: "DE123456789")

    result = resolve(source_ref: "ir-tax-1", name: "TaxMatch Variant", tax_id: "DE123456789")

    assert_equal vendor.id, result[:vendor].id
    assert_in_delta 1.0, result[:confidence].to_f, 0.001
    assert_equal true, result[:alias].is_confirmed
    assert_equal false, result[:was_created]
  end

  test "tax_id match is tenant-scoped: globex's tax_id not matched for acme" do
    Vendor.create!(tenant: @globex, canonical_name: "Globex TaxCo", tax_id: "US-EIN-9999")

    # Acme resolver with same tax_id — must NOT find globex's vendor.
    result = resolve(tenant: @acme, source_ref: "ir-x-1", name: "NewCo", tax_id: "US-EIN-9999")

    assert_equal true, result[:was_created], "expected a new vendor for acme, not globex's"
    assert_equal @acme.id, result[:vendor].tenant_id
  end

  # --------------------------------------------------------------------
  # Rung 3: normalized_name exact match (0.85, pending)
  # --------------------------------------------------------------------

  test "exact normalized_name match yields confidence 0.85 and pending alias" do
    Vendor.create!(tenant: @acme, canonical_name: "Widgets GmbH")

    result = resolve(source_ref: "ir-name-1", name: "Widgets Inc")

    # "Widgets GmbH" -> "widgets"; "Widgets Inc" -> "widgets"; exact normalized match.
    assert_in_delta 0.85, result[:confidence].to_f, 0.001
    assert_equal false, result[:alias].is_confirmed
    assert_equal false, result[:was_created]
  end

  # --------------------------------------------------------------------
  # Rung 4: Levenshtein <= threshold (0.70, pending)
  # --------------------------------------------------------------------

  test "Levenshtein match under threshold yields confidence 0.70 and pending alias" do
    Vendor.create!(tenant: @acme, canonical_name: "Widgets GmbH")

    # "Widgets GmbH" -> "widgets"; "Widgzts Inc" -> "widgzts"; distance 1 to "widgets".
    result = resolve(source_ref: "ir-lev-1", name: "Widgzts Inc")

    assert_in_delta 0.70, result[:confidence].to_f, 0.001
    assert_equal false, result[:alias].is_confirmed
    assert_equal false, result[:was_created]
  end

  test "Levenshtein above threshold yields NEW vendor" do
    Vendor.create!(tenant: @acme, canonical_name: "Widgets GmbH")

    # "widgets" vs "wombats" — distance 4, above default threshold of 2.
    result = resolve(source_ref: "ir-new-1", name: "Wombats Inc")

    assert_equal true, result[:was_created]
    assert_in_delta 1.0, result[:confidence].to_f, 0.001
  end

  # --------------------------------------------------------------------
  # Rung 5: new vendor creation
  # --------------------------------------------------------------------

  test "no match creates new vendor with alias at confidence 1.00" do
    result = resolve(source_ref: "brand-new-1", name: "Brand New Co")

    assert_equal true, result[:was_created]
    assert_equal "Brand New Co", result[:vendor].canonical_name
    assert_equal "brand new", result[:vendor].normalized_name
    assert_in_delta 1.0, result[:confidence].to_f, 0.001
    assert_equal true, result[:alias].is_confirmed
  end

  test "new vendor falls back to source_ref as canonical_name when name is nil" do
    result = resolve(source_ref: "SYS-12345", name: nil)

    assert_equal true, result[:was_created]
    assert_equal "SYS-12345", result[:vendor].canonical_name
  end

  test "new vendor copies tax_id and country_code from hints" do
    result = resolve(
      source_ref: "hints-001",
      name: "HintCo",
      tax_id: "DE555555555",
      country_code: "DE"
    )

    assert_equal true, result[:was_created]
    assert_equal "DE555555555", result[:vendor].tax_id
    assert_equal "DE", result[:vendor].country_code
  end

  # --------------------------------------------------------------------
  # Tenant isolation
  # --------------------------------------------------------------------

  test "same source_ref across tenants creates distinct vendors" do
    acme_result = resolve(tenant: @acme, source_ref: "shared-ref", name: "Acme Co")
    globex_result = resolve(tenant: @globex, source_ref: "shared-ref", name: "Globex Co")

    assert_not_equal acme_result[:vendor].id, globex_result[:vendor].id
    assert_equal @acme.id, acme_result[:vendor].tenant_id
    assert_equal @globex.id, globex_result[:vendor].tenant_id
  end

  # --------------------------------------------------------------------
  # Idempotency under rungs 3/4: re-resolving should hit rung 1 the 2nd time
  # --------------------------------------------------------------------

  test "second resolve of same source_ref after normalized_name match hits rung 1" do
    Vendor.create!(tenant: @acme, canonical_name: "Widgets GmbH")
    first = resolve(source_ref: "cached-after-name", name: "Widgets Inc")
    second = resolve(source_ref: "cached-after-name", name: "Widgets Inc")

    # First was rung 3 (0.85). Second must hit rung 1 (cached alias).
    assert_equal first[:vendor].id, second[:vendor].id
    assert_equal first[:alias].id, second[:alias].id
    # No duplicate alias row.
    assert_equal 1, VendorAlias.where(tenant_id: @acme.id, source_ref: "cached-after-name").count
  end
end
