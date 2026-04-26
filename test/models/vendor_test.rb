# frozen_string_literal: true

require "test_helper"

# Vendor — PRD §4.3. Tenant-scoped canonical directory. Every test here
# MUST load ≥2 tenant fixtures (Multi-Tenant Fixtures Mandatory in
# CODING_STANDARDS_TESTING.md).
class VendorTest < ActiveSupport::TestCase
  def setup
    @acme = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
  end

  def valid_attributes(overrides = {})
    {
      tenant: @acme,
      canonical_name: "Acme Supplier GmbH",
      country_code: "DE",
      tax_id: "DE123456789",
      category: "hardware",
      annual_spend_cents: 1_500_000_00,
      currency: "EUR",
      status: "active"
    }.merge(overrides)
  end

  test "valid with minimal required attributes" do
    v = Vendor.new(tenant: @acme, canonical_name: "Acme Supplier")
    assert v.valid?, v.errors.full_messages.to_sentence
  end

  test "canonical_name is required" do
    v = Vendor.new(tenant: @acme, canonical_name: nil)
    assert_not v.valid?
    assert_includes v.errors[:canonical_name], "can't be blank"
  end

  test "tenant is required" do
    v = Vendor.new(valid_attributes(tenant: nil))
    assert_not v.valid?
    assert_includes v.errors[:tenant], "must exist"
  end

  test "before_validation populates normalized_name from canonical_name" do
    v = Vendor.new(tenant: @acme, canonical_name: "Acme GmbH")
    v.valid?
    assert_equal "acme", v.normalized_name
  end

  test "normalized_name updates when canonical_name changes" do
    v = Vendor.create!(tenant: @acme, canonical_name: "Acme GmbH")
    assert_equal "acme", v.normalized_name

    v.canonical_name = "Beta Corp"
    v.valid?
    assert_equal "beta", v.normalized_name
  end

  test "status defaults to active" do
    v = Vendor.create!(tenant: @acme, canonical_name: "Defaulter")
    assert_equal "active", v.status
  end

  test "status rejects invalid values" do
    v = Vendor.new(valid_attributes(status: "bogus"))
    assert_not v.valid?
    assert_includes v.errors[:status], "is not included in the list"
  end

  test "status accepts all four enum values" do
    %w[active watchlist terminated merged].each do |s|
      v = Vendor.new(valid_attributes(status: s, canonical_name: "Vendor #{s}"))
      assert v.valid?, "status=#{s} should be valid: #{v.errors.full_messages}"
    end
  end

  test "tax_id uniqueness is tenant-scoped: same tax_id allowed across tenants" do
    Vendor.create!(tenant: @acme, canonical_name: "A Co", tax_id: "DE999999999")
    # Same tax_id on a DIFFERENT tenant — must be allowed.
    other = Vendor.new(tenant: @globex, canonical_name: "G Co", tax_id: "DE999999999")
    assert other.valid?, "same tax_id on a different tenant must be allowed: #{other.errors.full_messages}"
    assert other.save
  end

  test "tax_id uniqueness is enforced within tenant" do
    Vendor.create!(tenant: @acme, canonical_name: "A Co", tax_id: "DE999999999")
    dup = Vendor.new(tenant: @acme, canonical_name: "A2 Co", tax_id: "DE999999999")
    # Either the model validation or the unique DB index must reject.
    assert_not dup.valid?
    assert_includes dup.errors[:tax_id], "has already been taken"
  end

  test "tax_id nullability: multiple rows with null tax_id OK in same tenant" do
    Vendor.create!(tenant: @acme, canonical_name: "NullTax 1", tax_id: nil)
    v2 = Vendor.new(tenant: @acme, canonical_name: "NullTax 2", tax_id: nil)
    assert v2.valid?
    assert v2.save
  end

  test "tenant-isolation scope: for_tenant returns only tenant's rows" do
    a = Vendor.create!(tenant: @acme, canonical_name: "Acme One")
    g = Vendor.create!(tenant: @globex, canonical_name: "Globex One")

    acme_ids = Vendor.where(tenant_id: @acme.id).pluck(:id)
    globex_ids = Vendor.where(tenant_id: @globex.id).pluck(:id)

    assert_includes acme_ids, a.id
    assert_not_includes acme_ids, g.id
    assert_includes globex_ids, g.id
    assert_not_includes globex_ids, a.id
  end

  test "active scope returns only status=active rows" do
    Vendor.create!(tenant: @acme, canonical_name: "Kept", status: "active")
    Vendor.create!(tenant: @acme, canonical_name: "Gone", status: "terminated")

    names = Vendor.where(tenant_id: @acme.id).active.pluck(:canonical_name)
    assert_includes names, "Kept"
    assert_not_includes names, "Gone"
  end

  test "metadata defaults to empty hash" do
    v = Vendor.create!(tenant: @acme, canonical_name: "Meta-default")
    assert_equal({}, v.metadata)
  end

  test "has_many vendor_aliases with dependent destroy" do
    v = Vendor.create!(tenant: @acme, canonical_name: "With Aliases")
    v.vendor_aliases.create!(
      tenant: @acme,
      source_system: "manual",
      source_ref: "m-001",
      confidence: 1.0,
      is_confirmed: true
    )

    assert_equal 1, v.vendor_aliases.count

    v.destroy!
    assert_equal 0, VendorAlias.where(vendor_id: v.id).count
  end

  test "cross-tenant lookup: @acme's vendor must not appear in @globex scope" do
    a = Vendor.create!(tenant: @acme, canonical_name: "Acme Only")
    assert_nil Vendor.where(tenant_id: @globex.id).find_by(id: a.id)
  end
end
