# frozen_string_literal: true

require "test_helper"

# VendorAlias — PRD §4.4. Reconciles upstream (source_system, source_ref)
# tuples to a canonical vendor row within a tenant.
class VendorAliasTest < ActiveSupport::TestCase
  def setup
    @acme = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)

    @acme_vendor = Vendor.create!(tenant: @acme, canonical_name: "Acme Supplier")
    @globex_vendor = Vendor.create!(tenant: @globex, canonical_name: "Globex Supplier")
  end

  def valid_attributes(overrides = {})
    {
      tenant: @acme,
      vendor: @acme_vendor,
      source_system: "invoice_recon",
      source_ref: "ir-abc-123",
      alias_text: "Acme Supplier GmbH",
      confidence: 1.0,
      is_confirmed: true
    }.merge(overrides)
  end

  test "valid with required attributes" do
    a = VendorAlias.new(valid_attributes)
    assert a.valid?, a.errors.full_messages.to_sentence
  end

  test "tenant is required" do
    a = VendorAlias.new(valid_attributes(tenant: nil))
    assert_not a.valid?
    assert_includes a.errors[:tenant], "must exist"
  end

  test "vendor is required" do
    a = VendorAlias.new(valid_attributes(vendor: nil))
    assert_not a.valid?
    assert_includes a.errors[:vendor], "must exist"
  end

  test "source_system rejects invalid values" do
    a = VendorAlias.new(valid_attributes(source_system: "bogus"))
    assert_not a.valid?
    assert_includes a.errors[:source_system], "is not included in the list"
  end

  test "source_system accepts all PRD-defined values" do
    %w[invoice_recon webhook_engine contract_engine recon_engine rag_platform manual].each_with_index do |src, i|
      a = VendorAlias.new(valid_attributes(
        source_system: src,
        source_ref: "r-#{i}"
      ))
      assert a.valid?, "#{src} should be accepted"
    end
  end

  test "source_ref is required" do
    a = VendorAlias.new(valid_attributes(source_ref: nil))
    assert_not a.valid?
    assert_includes a.errors[:source_ref], "can't be blank"
  end

  test "confidence must be between 0.0 and 1.0" do
    [-0.1, 1.01, 2.0].each do |bad|
      a = VendorAlias.new(valid_attributes(confidence: bad, source_ref: "r-#{bad}"))
      assert_not a.valid?, "confidence #{bad} should be invalid"
    end
  end

  test "confidence endpoints 0.0 and 1.0 are accepted" do
    a0 = VendorAlias.new(valid_attributes(confidence: 0.0, source_ref: "r-zero"))
    a1 = VendorAlias.new(valid_attributes(confidence: 1.0, source_ref: "r-one"))
    assert a0.valid?
    assert a1.valid?
  end

  test "is_confirmed defaults to false" do
    a = VendorAlias.create!(
      tenant: @acme,
      vendor: @acme_vendor,
      source_system: "manual",
      source_ref: "m-default",
      confidence: 0.85
    )
    assert_equal false, a.is_confirmed
  end

  test "uniqueness on (tenant_id, source_system, source_ref)" do
    VendorAlias.create!(valid_attributes)
    dup = VendorAlias.new(valid_attributes)
    assert_not dup.valid?
    assert_includes dup.errors[:source_ref], "has already been taken"
  end

  test "same (source_system, source_ref) allowed across different tenants" do
    VendorAlias.create!(valid_attributes)

    other = VendorAlias.new(valid_attributes(
      tenant: @globex,
      vendor: @globex_vendor
    ))
    # Same source_system + source_ref but DIFFERENT tenant — allowed.
    assert other.valid?, "cross-tenant source_ref collision must be allowed: #{other.errors.full_messages}"
    assert other.save
  end

  test "dependent destroy: deleting vendor removes aliases" do
    VendorAlias.create!(valid_attributes)
    count = VendorAlias.where(vendor_id: @acme_vendor.id).count
    assert_equal 1, count
    @acme_vendor.destroy!
    assert_equal 0, VendorAlias.where(vendor_id: @acme_vendor.id).count
  end

  test "pending scope returns only unconfirmed aliases" do
    VendorAlias.create!(valid_attributes(source_ref: "ref-confirmed", is_confirmed: true))
    VendorAlias.create!(valid_attributes(source_ref: "ref-pending", is_confirmed: false, confidence: 0.7))

    pending_refs = VendorAlias.where(tenant_id: @acme.id).pending.pluck(:source_ref)
    assert_includes pending_refs, "ref-pending"
    assert_not_includes pending_refs, "ref-confirmed"
  end
end
